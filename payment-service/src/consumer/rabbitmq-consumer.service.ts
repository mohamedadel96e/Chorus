import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as amqplib from 'amqplib';
import { IdempotencyService } from './idempotency.service';
import { PaymentService } from '../payment/payment.service';

@Injectable()
export class RabbitMqConsumerService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RabbitMqConsumerService.name);
  private connection: any;
  private channel: any;
  private retryCounts = new Map<string, number>();

  constructor(
    private readonly idempotencyService: IdempotencyService,
    private readonly paymentService: PaymentService,
    private readonly configService: ConfigService,
  ) {}

  async onModuleInit() {
    await this.connect();
  }

  async connect() {
    try {
      const amqpUrl = this.configService.get<string>('RABBITMQ_URL') || 'amqp://guest:guest@localhost:5672';
      this.connection = await amqplib.connect(amqpUrl);
      this.channel = await this.connection.createChannel();

      const exchange = 'chorus.events';

      // We will assert and bind two queues
      const reservedQueue = 'payment.inventory.reserved';
      const reservedKey = 'inventory.reserved';

      const shipmentFailedQueue = 'payment.shipment.failed';
      const shipmentFailedKey = 'shipment.failed';

      await this.channel.assertExchange(exchange, 'topic', { durable: true });

      // Setup Dead-Letter Exchange and Queue
      const dlx = 'chorus.dlx';
      const dlq = 'chorus.dlq';
      await this.channel.assertExchange(dlx, 'fanout', { durable: true });
      await this.channel.assertQueue(dlq, { durable: true });
      await this.channel.bindQueue(dlq, dlx, '');

      await this.channel.assertQueue(reservedQueue, { 
        durable: true,
        arguments: { 'x-dead-letter-exchange': dlx }
      });
      await this.channel.bindQueue(reservedQueue, exchange, reservedKey);

      await this.channel.assertQueue(shipmentFailedQueue, { 
        durable: true,
        arguments: { 'x-dead-letter-exchange': dlx }
      });
      await this.channel.bindQueue(shipmentFailedQueue, exchange, shipmentFailedKey);

      await this.channel.prefetch(1);

      this.logger.log(`Listening on queues: ${reservedQueue}, ${shipmentFailedQueue}`);

      // Consumer for inventory.reserved
      this.channel.consume(
        reservedQueue,
        async (msg) => {
          if (!msg) return;
          await this.handleMessage(msg, async (envelope) => {
            const payload = envelope.payload;
            const correlationId = envelope.correlation_id;
            this.logger.log(
              `Processing charge for order: ${payload.order_id} (Correlation: ${correlationId})`,
            );
            await this.paymentService.processCharge(payload, correlationId);
          });
        },
        { noAck: false },
      );

      // Consumer for shipment.failed
      this.channel.consume(
        shipmentFailedQueue,
        async (msg) => {
          if (!msg) return;
          await this.handleMessage(msg, async (envelope) => {
            const payload = envelope.payload;
            const correlationId = envelope.correlation_id;
            this.logger.log(
              `Processing refund for order: ${payload.order_id} (Correlation: ${correlationId})`,
            );
            await this.paymentService.refundPayment(payload, correlationId);
          });
        },
        { noAck: false },
      );
    } catch (error) {
      this.logger.error('Failed to connect to RabbitMQ', error);
      setTimeout(() => this.connect(), 5000); // Retry after 5s
    }
  }

  private async handleMessage(msg: any, handler: (payload: any) => Promise<void>) {
    try {
      const content = JSON.parse(msg.content.toString());
      const eventId = content.event_id;

      await this.idempotencyService.executeIdempotent(eventId, async (manager) => {
        await handler(content);
      });

      this.retryCounts.delete(eventId);
      this.channel.ack(msg);
    } catch (error) {
      const isRedelivered = msg.fields.redelivered;
      this.logger.error(`Error processing message (Redelivered: ${isRedelivered}): ${error.message}`, error.stack);
      
      let requeue = true;
      try {
        const content = JSON.parse(msg.content.toString());
        const eventId = content.event_id;
        
        if (eventId) {
          const count = (this.retryCounts.get(eventId) || 0) + 1;
          this.retryCounts.set(eventId, count);
          if (count >= 3) {
            requeue = false;
            this.retryCounts.delete(eventId);
            this.logger.warn(`Message failed 3 times, routing to DLQ for event: ${eventId}`);
          }
        } else {
          requeue = !isRedelivered;
        }
      } catch (parseError) {
        requeue = !isRedelivered;
      }

      if (!requeue) {
        this.logger.warn('Message failed multiple times, routing to DLQ.');
      }
      this.channel.nack(msg, false, requeue);
    }
  }

  async onModuleDestroy() {
    if (this.channel) await this.channel.close();
    if (this.connection) await this.connection.close();
  }
}
