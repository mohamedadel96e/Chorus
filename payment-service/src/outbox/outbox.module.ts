import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OutboxEvent } from './outbox-event.entity';
import { ProcessedEvent } from './processed-event.entity';
import { OutboxService } from './outbox.service';

@Module({
  imports: [TypeOrmModule.forFeature([OutboxEvent, ProcessedEvent])],
  providers: [OutboxService],
  exports: [TypeOrmModule], // Export so other modules can insert into the outbox
})
export class OutboxModule {}
