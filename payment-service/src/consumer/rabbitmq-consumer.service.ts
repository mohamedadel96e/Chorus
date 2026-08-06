import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import * as amqplib from 'amqplib';
import { IdempotencyService } from './idempotency.service';

@Injectable()
export class RabbitMqConsumerService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RabbitMqConsumerService.name);
  private connection: any;
  private channel: any;

  constructor(private readonly idempotencyService: IdempotencyService) {}

  async onModuleInit() {
    await this.connect();
  }

  async connect() {
    try {
      this.connection = await amqplib.connect('amqp://guest:guest@localhost:5672');
      this.channel = await this.connection.createChannel();
      
      const exchange = 'chorus.events';
      const queue = 'payment.inventory.reserved';
      const routingKey = 'inventory.reserved';

      await this.channel.assertExchange(exchange, 'topic', { durable: true });
      await this.channel.assertQueue(queue, { durable: true });
      await this.channel.bindQueue(queue, exchange, routingKey);

      // Preheat count to 1 for fair dispatch and explicit manual ack
      await this.channel.prefetch(1);

      this.logger.log(`Listening on queue ${queue} for routing key ${routingKey}`);

      this.channel.consume(queue, async (msg) => {
        if (!msg) return;

        try {
          const content = JSON.parse(msg.content.toString());
          const eventId = content.event_id;
          const correlationId = content.correlation_id;

          this.logger.log(`Received inventory.reserved event [event_id: ${eventId}, correlation_id: ${correlationId}]`);

          await this.idempotencyService.executeIdempotent(eventId, async (manager) => {
            // Dummy business logic for Phase 3
            this.logger.log(`Processing business logic for inventory.reserved (Correlation: ${correlationId})`);
          });

          this.channel.ack(msg);
        } catch (error) {
          this.logger.error(`Error processing message: ${error.message}`, error.stack);
          // Nack and requeue
          this.channel.nack(msg, false, true);
        }
      }, { noAck: false }); // Manual ack

    } catch (error) {
      this.logger.error('Failed to connect to RabbitMQ', error);
      setTimeout(() => this.connect(), 5000); // Retry after 5s
    }
  }

  async onModuleDestroy() {
    if (this.channel) await this.channel.close();
    if (this.connection) await this.connection.close();
  }
}
