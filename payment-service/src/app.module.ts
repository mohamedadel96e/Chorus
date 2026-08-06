import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ScheduleModule } from '@nestjs/schedule';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { OutboxModule } from './outbox/outbox.module';
import { OutboxEvent } from './outbox/outbox-event.entity';
import { ProcessedEvent } from './outbox/processed-event.entity';
import { PaymentModule } from './payment/payment.module';
import { PaymentRecord } from './payment/payment-record.entity';
import { ConsumerModule } from './consumer/consumer.module';

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: 'localhost',
      port: 5432,
      username: 'postgres',
      password: 'password',
      database: 'payment_db',
      entities: [OutboxEvent, ProcessedEvent, PaymentRecord],
      synchronize: true, // Use only in development
    }),
    ScheduleModule.forRoot(),
    OutboxModule,
    PaymentModule,
    ConsumerModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
