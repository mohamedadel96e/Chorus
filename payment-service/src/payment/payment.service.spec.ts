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

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  it('should process payment successfully and save outbox event', async () => {
    jest.spyOn(Math, 'random').mockReturnValue(0.5);

    const payload = {
      order_id: 'order-123',
      total_amount_cents: 1000,
      currency: 'USD',
    };

    await service.processCharge(payload, 'corr-123');

    expect(mockQueryRunner.startTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.manager.save).toHaveBeenCalledTimes(2);

    const savedPayment = mockQueryRunner.manager.save.mock.calls[0][0];
    expect(savedPayment).toBeInstanceOf(PaymentRecord);
    expect(savedPayment.orderId).toBe('order-123');
    expect(savedPayment.amountCents).toBe(1000);
    expect(savedPayment.currency).toBe('USD');
    expect(savedPayment.status).toBe('SUCCESS');

    const savedOutbox = mockQueryRunner.manager.save.mock.calls[1][0];
    expect(savedOutbox.eventType).toBe('PaymentCharged');
    expect(savedOutbox.routingKey).toBe('payment.charged');
    expect(savedOutbox.correlationId).toBe('corr-123');
    expect(savedOutbox.payload).toEqual({
      order_id: 'order-123',
      payment_id: 'payment-id-123',
      amount_cents: 1000,
      currency: 'USD',
    });

    expect(mockQueryRunner.commitTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.release).toHaveBeenCalled();
  });

  it('should process failed payment and save failure outbox event', async () => {
    jest.spyOn(Math, 'random').mockReturnValue(0.05);

    const payload = {
      order_id: 'order-123',
      total_amount_cents: 1000,
      currency: 'USD',
    };

    await service.processCharge(payload, 'corr-123');

    expect(mockQueryRunner.startTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.manager.save).toHaveBeenCalledTimes(2);

    const savedPayment = mockQueryRunner.manager.save.mock.calls[0][0];
    expect(savedPayment.status).toBe('FAILED');

    const savedOutbox = mockQueryRunner.manager.save.mock.calls[1][0];
    expect(savedOutbox.eventType).toBe('PaymentFailed');
    expect(savedOutbox.routingKey).toBe('payment.failed');
    expect(savedOutbox.payload.reason).toBe('Simulated payment failure');

    expect(mockQueryRunner.commitTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.release).toHaveBeenCalled();
  });

  it('should rollback transaction on database error', async () => {
    mockQueryRunner.manager.save.mockRejectedValueOnce(new Error('Database write error'));

    const payload = {
      order_id: 'order-123',
      total_amount_cents: 1000,
      currency: 'USD',
    };

    await expect(service.processCharge(payload, 'corr-123')).rejects.toThrow('Database write error');

    expect(mockQueryRunner.rollbackTransaction).toHaveBeenCalled();
    expect(mockQueryRunner.release).toHaveBeenCalled();
  });
});
