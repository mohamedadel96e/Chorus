import { Injectable, Logger, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { OutboxEvent } from './outbox-event.entity';
import * as amqp from 'amqplib';

@Injectable()
export class OutboxService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(OutboxService.name);
  private connection: any;
  private channel: any;
  private readonly exchange = 'chorus.events';

  constructor(
    @InjectRepository(OutboxEvent)
    private readonly outboxRepo: Repository<OutboxEvent>,
  ) {}

  async onModuleInit() {
    try {
      // Connect to RabbitMQ (in a real app, URL should be in env config)
      this.connection = await amqp.connect('amqp://guest:guest@localhost:5672');
      this.channel = await this.connection.createChannel();
      
      // Ensure the exchange exists
      await this.channel.assertExchange(this.exchange, 'topic', { durable: true });
      this.logger.log('Connected to RabbitMQ and asserted exchange');
    } catch (error) {
      this.logger.error('Failed to connect to RabbitMQ', error);
    }
  }

  async onModuleDestroy() {
    if (this.channel) await this.channel.close();
    if (this.connection) await this.connection.close();
  }

  @Cron(CronExpression.EVERY_5_SECONDS)
  async relayEvents() {
    if (!this.channel) {
      this.logger.warn('RabbitMQ channel not ready');
      return;
    }

    const pendingEvents = await this.outboxRepo.find({
      where: { status: 'PENDING' },
      order: { occurredAt: 'ASC' },
    });

    if (pendingEvents.length === 0) return;

    this.logger.log(`Found ${pendingEvents.length} pending outbox events`);

    for (const event of pendingEvents) {
      try {
        const payloadStr = JSON.stringify(event.payload);
        
        const published = this.channel.publish(
          this.exchange,
          event.routingKey,
          Buffer.from(payloadStr),
          {
            messageId: event.id,
            correlationId: event.correlationId,
            contentType: 'application/json',
            timestamp: event.occurredAt.getTime(),
            persistent: true, // deliveryMode = 2
          }
        );

        if (published) {
          event.status = 'PUBLISHED';
          await this.outboxRepo.save(event);
          this.logger.log(`Successfully published event ${event.id} with routing key ${event.routingKey}`);
        }
      } catch (error) {
        this.logger.error(`Failed to publish event ${event.id}`, error);
      }
    }
  }
}
