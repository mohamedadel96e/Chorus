<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use PhpAmqpLib\Connection\AMQPStreamConnection;
use PhpAmqpLib\Message\AMQPMessage;
use App\Traits\HandlesIdempotentEvents;
use Illuminate\Support\Facades\Log;

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

        $channel->exchange_declare($exchange, 'topic', false, true, false);
        $channel->queue_declare($queue, false, true, false, false);
        $channel->queue_bind($queue, $exchange, $routingKey);
        
        $channel->basic_qos(null, 1, null);

        $this->info("Listening for payment.charged events...");

        $callback = function (AMQPMessage $msg) {
            try {
                $payload = json_decode($msg->body, true);
                $eventId = $payload['event_id'] ?? null;
                $correlationId = $payload['correlation_id'] ?? null;

                if (!$eventId) {
                    $this->error("Received message without event_id: " . $msg->body);
                    $msg->ack();
                    return;
                }

                $this->info("Received payment.charged event [event_id: {$eventId}, correlation_id: {$correlationId}]");

                $this->handleIdempotentEvent($eventId, function () use ($correlationId) {
                    // Dummy business logic for Phase 3
                    Log::info("Processing business logic for payment.charged (Correlation: {$correlationId})");
                    $this->info("Processed successfully.");
                });

                $msg->ack();
            } catch (\Exception $e) {
                $this->error("Error processing message: " . $e->getMessage());
                $msg->nack(true);
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
