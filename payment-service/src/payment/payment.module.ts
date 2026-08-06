import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { PaymentRecord } from './payment-record.entity';
import { PaymentService } from './payment.service';
import { PaymentController } from './payment.controller';
import { OutboxEvent } from '../outbox/outbox-event.entity';

@Module({
  imports: [TypeOrmModule.forFeature([PaymentRecord, OutboxEvent])],
  providers: [PaymentService],
  controllers: [PaymentController],
})
export class PaymentModule {}
