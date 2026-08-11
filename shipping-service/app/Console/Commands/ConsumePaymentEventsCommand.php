<?php

namespace App\Console\Commands;

use App\Services\ShippingService;
use App\Traits\HandlesIdempotentEvents;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;
use PhpAmqpLib\Connection\AMQPStreamConnection;
use PhpAmqpLib\Message\AMQPMessage;

class ConsumePaymentEventsCommand extends Command
{
    use HandlesIdempotentEvents;

    protected $signature = 'rabbitmq:consume-payment-events';

    protected $description = 'Consume payment events and execute business logic idempotently';

    public function handle()
    {
        $connection = new AMQPStreamConnection('localhost', 5672, 'guest', 'guest');
        $channel = $connection->channel();

        $exchange = 'chorus.events';
        $queue = 'shipping.payment.charged';
        $routingKey = 'payment.charged';

        $dlx = 'chorus.dlx';
        $dlq = 'chorus.dlq';

        $channel->exchange_declare($exchange, 'topic', false, true, false);
        
        // Setup Dead-Letter Exchange and Queue
        $channel->exchange_declare($dlx, 'fanout', false, true, false);
        $channel->queue_declare($dlq, false, true, false, false);
        $channel->queue_bind($dlq, $dlx);

        $args = new \PhpAmqpLib\Wire\AMQPTable([
            'x-dead-letter-exchange' => $dlx
        ]);

        $channel->queue_declare($queue, false, true, false, false, false, $args);
        $channel->queue_bind($queue, $exchange, $routingKey);

        $channel->basic_qos(null, 1, null);

        $this->info('Listening for payment.charged events...');

        $retryCounts = [];

        $callback = function (AMQPMessage $msg) use (&$retryCounts) {
            try {
                $payload = json_decode($msg->body, true);
                $eventId = $payload['event_id'] ?? null;
                $correlationId = $payload['correlation_id'] ?? null;

                if (! $eventId) {
                    $this->error('Received message without event_id: '.$msg->body);
                    $msg->ack();

                    return;
                }

                $this->info("Received payment.charged event [event_id: {$eventId}, correlation_id: {$correlationId}]");

                $this->handleIdempotentEvent($eventId, function () use ($payload, $correlationId) {
                    $shippingService = app(ShippingService::class);
                    $innerPayload = $payload['payload'] ?? [];
                    $shippingService->createShipment($innerPayload, $correlationId);
                    Log::info("Processing business logic for payment.charged (Correlation: {$correlationId})");
                    $this->info('Processed successfully.');
                });

                unset($retryCounts[$eventId]);
                $msg->ack();
            } catch (\Exception $e) {
                $isRedelivered = $msg->delivery_info['redelivered'] ?? false;
                $this->error("Error processing message (Redelivered: " . ($isRedelivered ? 'true' : 'false') . "): " . $e->getMessage());
                
                $requeue = true;
                try {
                    $payload = json_decode($msg->body, true);
                    $eventId = $payload['event_id'] ?? null;
                    
                    if ($eventId) {
                        $count = ($retryCounts[$eventId] ?? 0) + 1;
                        $retryCounts[$eventId] = $count;
                        if ($count >= 3) {
                            $requeue = false;
                            unset($retryCounts[$eventId]);
                            $this->warn("Message failed 3 times, routing to DLQ for event: {$eventId}");
                        }
                    } else {
                        $requeue = !$isRedelivered;
                    }
                } catch (\Exception $parseError) {
                    $requeue = !$isRedelivered;
                }
                
                if (!$requeue) {
                    $this->warn('Message failed multiple times, routing to DLQ.');
                }
                $msg->nack($requeue);
            }
        };

        $channel->basic_consume($queue, '', false, false, false, false, $callback);

        while ($channel->is_open()) {
            $channel->wait();
        }

        $channel->close();
        $connection->close();
    }
}
