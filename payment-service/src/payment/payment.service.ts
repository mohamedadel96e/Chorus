import { Injectable, BadRequestException, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, DataSource } from 'typeorm';
import { PaymentRecord } from './payment-record.entity';
import { OutboxEvent } from '../outbox/outbox-event.entity';
import { randomUUID } from 'crypto';

@Injectable()
export class PaymentService {
  private readonly logger = new Logger(PaymentService.name);

  constructor(
    @InjectRepository(PaymentRecord)
    private paymentRepo: Repository<PaymentRecord>,
    private dataSource: DataSource,
  ) {}

  async processCharge(payload: any, correlationId: string): Promise<void> {
    const orderId = payload.order_id;
    const amountCents = payload.total_amount_cents || 10000; // fallback if missing
    const currency = payload.currency || 'USD';

    const queryRunner = this.dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();

    try {
      const isFailure = Math.random() < 0.1; // 10% chance to fail

      const payment = new PaymentRecord();
      payment.orderId = orderId;
      payment.amountCents = amountCents;
      payment.currency = currency;
      payment.status = isFailure ? 'FAILED' : 'SUCCESS';

      const savedPayment = await queryRunner.manager.save(payment);

      const outboxEvent = new OutboxEvent();
      outboxEvent.eventType = isFailure ? 'PaymentFailed' : 'PaymentCharged';
      outboxEvent.routingKey = isFailure ? 'payment.failed' : 'payment.charged';
      outboxEvent.correlationId = correlationId;
      outboxEvent.payload = {
        order_id: orderId,
        payment_id: savedPayment.id.toString(),
        amount_cents: amountCents,
        currency: currency,
      };

      if (isFailure) {
        outboxEvent.payload.reason = 'Simulated payment failure';
      }
      outboxEvent.status = 'PENDING';
      outboxEvent.occurredAt = new Date();

      await queryRunner.manager.save(outboxEvent);

      await queryRunner.commitTransaction();
      this.logger.log(`Payment processed for order ${orderId}: ${savedPayment.status}`);
    } catch (error) {
      await queryRunner.rollbackTransaction();
      this.logger.error(`Error processing charge for order ${orderId}`, error.stack);
      throw error;
    } finally {
      await queryRunner.release();
    }
  }

  async refundPayment(payload: any, correlationId: string): Promise<void> {
    const orderId = payload.order_id;

    const queryRunner = this.dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();

    try {
      // Find the successful payment
      const payment = await queryRunner.manager.findOne(PaymentRecord, {
        where: { orderId, status: 'SUCCESS' },
      });

      if (!payment) {
        this.logger.warn(`No SUCCESS payment found for order ${orderId} to refund.`);
        await queryRunner.rollbackTransaction();
        return;
      }

      payment.status = 'REFUNDED';
      await queryRunner.manager.save(payment);

      const outboxEvent = new OutboxEvent();
      outboxEvent.eventType = 'PaymentRefunded';
      outboxEvent.routingKey = 'payment.refunded';
      outboxEvent.correlationId = correlationId;
      outboxEvent.payload = {
        order_id: orderId,
        payment_id: payment.id.toString(),
        refund_id: 'ref-' + randomUUID().substring(0, 8),
        amount_cents: payment.amountCents,
        currency: payment.currency,
        reason: 'Shipment failed - refunding customer',
      };
      outboxEvent.status = 'PENDING';
      outboxEvent.occurredAt = new Date();

      await queryRunner.manager.save(outboxEvent);

      await queryRunner.commitTransaction();
      this.logger.log(`Payment refunded for order ${orderId}`);
    } catch (error) {
      await queryRunner.rollbackTransaction();
      this.logger.error(`Error refunding payment for order ${orderId}`, error.stack);
      throw error;
    } finally {
      await queryRunner.release();
    }
  }
}
