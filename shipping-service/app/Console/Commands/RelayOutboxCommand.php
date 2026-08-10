<?php

namespace App\Console\Commands;

use App\Models\OutboxEvent;
use Illuminate\Console\Command;
use PhpAmqpLib\Connection\AMQPStreamConnection;
use PhpAmqpLib\Message\AMQPMessage;

class RelayOutboxCommand extends Command
{
    /**
     * The name and signature of the console command.
     *
     * @var string
     */
    protected $signature = 'outbox:relay';

    /**
     * The console command description.
     *
     * @var string
     */
    protected $description = 'Relay pending outbox events to RabbitMQ';

    /**
     * Execute the console command.
     */
    public function handle()
    {
        $pendingEvents = OutboxEvent::where('status', 'PENDING')
            ->orderBy('occurred_at', 'asc')
            ->get();

        if ($pendingEvents->isEmpty()) {
            return;
        }

        $this->info("Found {$pendingEvents->count()} pending outbox events");

        try {
            // In a real app, use config() for these credentials
            $connection = app()->bound(AMQPStreamConnection::class)
                ? app(AMQPStreamConnection::class)
                : new AMQPStreamConnection('localhost', 5672, 'guest', 'guest');
            $channel = $connection->channel();

            $exchange = 'chorus.events';
            $channel->exchange_declare($exchange, 'topic', false, true, false);

            foreach ($pendingEvents as $event) {
                try {
                    $envelope = [
                        'event_id' => $event->id,
                        'event_type' => $event->event_type,
                        'event_version' => 1,
                        'correlation_id' => $event->correlation_id,
                        'occurred_at' => $event->occurred_at->toIso8601String(),
                        'payload' => $event->payload,
                    ];
                    $payloadStr = json_encode($envelope);

                    $msg = new AMQPMessage($payloadStr, [
                        'content_type' => 'application/json',
                        'delivery_mode' => AMQPMessage::DELIVERY_MODE_PERSISTENT,
                        'message_id' => $event->id,
                        'correlation_id' => $event->correlation_id,
                        'timestamp' => $event->occurred_at->timestamp,
                    ]);

                    $channel->basic_publish($msg, $exchange, $event->routing_key);

                    $event->status = 'PUBLISHED';
                    $event->save();

                    $this->info("Successfully published event {$event->id} with routing key {$event->routing_key}");
                } catch (\Exception $e) {
                    $this->error("Failed to publish event {$event->id}: ".$e->getMessage());
                }
            }

            $channel->close();
            $connection->close();

        } catch (\Exception $e) {
            $this->error('Failed to connect to RabbitMQ: '.$e->getMessage());
        }
    }
}
