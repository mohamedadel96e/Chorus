import { Injectable, BadRequestException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, DataSource } from 'typeorm';
import { PaymentRecord } from './payment-record.entity';
import { OutboxEvent } from '../outbox/outbox-event.entity';

export interface ChargeRequest {
  orderId: string;
  amountCents: number;
  currency: string;
}

@Injectable()
export class PaymentService {
  constructor(
    @InjectRepository(PaymentRecord)
    private paymentRepo: Repository<PaymentRecord>,
    private dataSource: DataSource,
  ) {}

  async charge(request: ChargeRequest): Promise<{ paymentId: string; status: string; message: string }> {
    if (request.amountCents <= 0) {
      throw new BadRequestException('Amount must be greater than zero');
    }

    const queryRunner = this.dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();

    try {
      const payment = new PaymentRecord();
      payment.orderId = request.orderId;
      payment.amountCents = request.amountCents;
      payment.currency = request.currency;
      payment.status = 'SUCCESS';
      
      const savedPayment = await queryRunner.manager.save(payment);

      const outboxEvent = new OutboxEvent();
      outboxEvent.eventType = 'PaymentProcessed';
      outboxEvent.routingKey = 'payment.processed';
      outboxEvent.correlationId = request.orderId;
      outboxEvent.payload = {
        paymentId: savedPayment.id,
        orderId: request.orderId,
        status: 'SUCCESS'
      };
      outboxEvent.status = 'PENDING';
      outboxEvent.occurredAt = new Date();
      
      await queryRunner.manager.save(outboxEvent);

      await queryRunner.commitTransaction();

      return {
        paymentId: savedPayment.id,
        status: savedPayment.status,
        message: 'Payment charged successfully'
      };
    } catch (error) {
      await queryRunner.rollbackTransaction();
      throw error;
    } finally {
      await queryRunner.release();
    }
  }
}
