import { Test, TestingModule } from '@nestjs/testing';
import { IdempotencyService } from './idempotency.service';
import { DataSource } from 'typeorm';

describe('IdempotencyService', () => {
  let service: IdempotencyService;
  let dataSource: any;
  let queryRunner: any;
  let manager: any;

  beforeEach(async () => {
    manager = {
      insert: jest.fn(),
    };

    queryRunner = {
      connect: jest.fn(),
      startTransaction: jest.fn(),
      commitTransaction: jest.fn(),
      rollbackTransaction: jest.fn(),
      release: jest.fn(),
      manager,
    };

    dataSource = {
      createQueryRunner: jest.fn().mockReturnValue(queryRunner),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [IdempotencyService, { provide: DataSource, useValue: dataSource }],
    }).compile();

    service = module.get<IdempotencyService>(IdempotencyService);
  });

  it('should execute action when event is new', async () => {
    const action = jest.fn().mockResolvedValue(undefined);
    await service.executeIdempotent('event-1', action);

    expect(manager.insert).toHaveBeenCalled();
    expect(action).toHaveBeenCalledWith(manager);
    expect(queryRunner.commitTransaction).toHaveBeenCalled();
    expect(queryRunner.rollbackTransaction).not.toHaveBeenCalled();
    expect(queryRunner.release).toHaveBeenCalled();
  });

  it('should skip action when event is duplicate', async () => {
    const action = jest.fn();
    manager.insert.mockRejectedValue({ code: '23505' }); // Postgres duplicate

    await service.executeIdempotent('event-2', action);

    expect(manager.insert).toHaveBeenCalled();
    expect(action).not.toHaveBeenCalled();
    expect(queryRunner.commitTransaction).not.toHaveBeenCalled();
    expect(queryRunner.rollbackTransaction).toHaveBeenCalled();
    expect(queryRunner.release).toHaveBeenCalled();
  });

  it('should throw error for other errors', async () => {
    const action = jest.fn();
    manager.insert.mockRejectedValue(new Error('DB connection failed'));

    await expect(service.executeIdempotent('event-3', action)).rejects.toThrow(
      'DB connection failed',
    );

    expect(manager.insert).toHaveBeenCalled();
    expect(action).not.toHaveBeenCalled();
    expect(queryRunner.commitTransaction).not.toHaveBeenCalled();
    expect(queryRunner.rollbackTransaction).toHaveBeenCalled();
    expect(queryRunner.release).toHaveBeenCalled();
  });
});
