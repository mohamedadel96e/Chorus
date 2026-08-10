import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import * as amqplib from 'amqplib';
import { IdempotencyService } from './idempotency.service';
import { PaymentService } from '../payment/payment.service';

@Injectable()
export class RabbitMqConsumerService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(RabbitMqConsumerService.name);
  private connection: any;
  private channel: any;

  constructor(
    private readonly idempotencyService: IdempotencyService,
    private readonly paymentService: PaymentService,
  ) {}

  async onModuleInit() {
    await this.connect();
  }

  async connect() {
    try {
      this.connection = await amqplib.connect('amqp://guest:guest@localhost:5672');
      this.channel = await this.connection.createChannel();

      const exchange = 'chorus.events';

      // We will assert and bind two queues
      const reservedQueue = 'payment.inventory.reserved';
      const reservedKey = 'inventory.reserved';

      const shipmentFailedQueue = 'payment.shipment.failed';
      const shipmentFailedKey = 'shipment.failed';

      await this.channel.assertExchange(exchange, 'topic', { durable: true });

      await this.channel.assertQueue(reservedQueue, { durable: true });
      await this.channel.bindQueue(reservedQueue, exchange, reservedKey);

      await this.channel.assertQueue(shipmentFailedQueue, { durable: true });
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

      this.channel.ack(msg);
    } catch (error) {
      this.logger.error(`Error processing message: ${error.message}`, error.stack);
      this.channel.nack(msg, false, true);
    }
  }

  async onModuleDestroy() {
    if (this.channel) await this.channel.close();
    if (this.connection) await this.connection.close();
  }
}
