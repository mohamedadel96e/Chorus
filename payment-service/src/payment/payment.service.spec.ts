import { Test, TestingModule } from '@nestjs/testing';
import { PaymentService } from './payment.service';
import { DataSource } from 'typeorm';
import { BadRequestException } from '@nestjs/common';
import { getRepositoryToken } from '@nestjs/typeorm';
import { PaymentRecord } from './payment-record.entity';

describe('PaymentService', () => {
  let service: PaymentService;
  let mockQueryRunner: any;

  beforeEach(async () => {
    mockQueryRunner = {
      connect: jest.fn(),
      startTransaction: jest.fn(),
      commitTransaction: jest.fn(),
      rollbackTransaction: jest.fn(),
      release: jest.fn(),
      manager: {
        save: jest.fn((entity) => {
          if (!entity.id && entity.constructor.name === 'PaymentRecord') {
            entity.id = 'payment-id-123';
          }
          return Promise.resolve(entity);
        }),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        PaymentService,
        {
          provide: getRepositoryToken(PaymentRecord),
          useValue: {},
        },
        {
          provide: DataSource,
          useValue: {
            createQueryRunner: jest.fn().mockReturnValue(mockQueryRunner),
          },
        },
      ],
    }).compile();

    service = module.get<PaymentService>(PaymentService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  it('should process payment and save outbox event', async () => {
    const request = {
      orderId: 'order-123',
      amountCents: 1000,
      currency: 'USD',
    };

    const result = await service.charge(request);

    expect(result.paymentId).toEqual('payment-id-123');
    expect(result.status).toEqual('SUCCESS');
    expect(mockQueryRunner.startTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.manager.save).toHaveBeenCalledTimes(2); // PaymentRecord and OutboxEvent
    expect(mockQueryRunner.commitTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.release).toHaveBeenCalled();
  });

  it('should throw error for invalid amount', async () => {
    const request = {
      orderId: 'order-123',
      amountCents: 0,
      currency: 'USD',
    };

    await expect(service.charge(request)).rejects.toThrow(BadRequestException);
    expect(mockQueryRunner.startTransaction).not.toHaveBeenCalled();
  });
});
