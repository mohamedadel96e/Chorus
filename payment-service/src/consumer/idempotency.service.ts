import { Injectable, Logger } from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { ProcessedEvent } from '../outbox/processed-event.entity';

@Injectable()
export class IdempotencyService {
  private readonly logger = new Logger(IdempotencyService.name);

  constructor(private readonly dataSource: DataSource) {}

  async executeIdempotent(
    eventId: string,
    action: (manager: EntityManager) => Promise<void>,
  ): Promise<void> {
    const queryRunner = this.dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();

    try {
      const processedEvent = new ProcessedEvent();
      processedEvent.eventId = eventId;
      processedEvent.processedAt = new Date();

      await queryRunner.manager.insert(ProcessedEvent, processedEvent);

      await action(queryRunner.manager);

      await queryRunner.commitTransaction();
    } catch (error) {
      if (error.code === '23505') { // Postgres unique constraint violation
        await queryRunner.rollbackTransaction();
        this.logger.warn(`Duplicate event detected: ${eventId}. Skipping execution to maintain idempotency.`);
        return;
      }

      await queryRunner.rollbackTransaction();
      throw error;
    } finally {
      await queryRunner.release();
    }
  }
}
