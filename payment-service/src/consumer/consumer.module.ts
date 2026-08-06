import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { IdempotencyService } from './idempotency.service';
import { RabbitMqConsumerService } from './rabbitmq-consumer.service';
import { ProcessedEvent } from '../outbox/processed-event.entity';

@Module({
  imports: [TypeOrmModule.forFeature([ProcessedEvent])],
  providers: [IdempotencyService, RabbitMqConsumerService],
  exports: [IdempotencyService],
})
export class ConsumerModule {}
