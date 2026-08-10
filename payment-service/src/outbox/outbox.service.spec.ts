import { Test, TestingModule } from '@nestjs/testing';
import { OutboxService } from './outbox.service';
import { getRepositoryToken } from '@nestjs/typeorm';
import { OutboxEvent } from './outbox-event.entity';
import { ProcessedEvent } from './processed-event.entity';
import * as amqplib from 'amqplib';

jest.mock('amqplib');

describe('OutboxService', () => {
  let service: OutboxService;
  let outboxRepository: any;

  beforeEach(async () => {
    outboxRepository = {
      find: jest.fn(),
      save: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        OutboxService,
        {
          provide: getRepositoryToken(OutboxEvent),
          useValue: outboxRepository,
        },
        {
          provide: getRepositoryToken(ProcessedEvent),
          useValue: {},
        },
      ],
    }).compile();

    service = module.get<OutboxService>(OutboxService);
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  it('should relay pending events', async () => {
    const mockChannel = {
      assertExchange: jest.fn(),
      publish: jest.fn().mockReturnValue(true),
    };
    const mockConnection = {
      createChannel: jest.fn().mockResolvedValue(mockChannel),
      close: jest.fn(),
    };
    (amqplib.connect as jest.Mock).mockResolvedValue(mockConnection);

    const occurredAt = new Date();
    const pendingEvent = new OutboxEvent();
    pendingEvent.id = 'uuid';
    pendingEvent.eventType = 'PaymentCharged';
    pendingEvent.routingKey = 'payment.processed';
    pendingEvent.correlationId = 'corr-123';
    pendingEvent.payload = { data: 'test' };
    pendingEvent.status = 'PENDING';
    pendingEvent.occurredAt = occurredAt;
    outboxRepository.find.mockResolvedValue([pendingEvent]);

    await service.onModuleInit();
    await service.relayEvents();

    expect(outboxRepository.find).toHaveBeenCalled();

    const expectedEnvelope = {
      event_id: 'uuid',
      event_type: 'PaymentCharged',
      event_version: 1,
      correlation_id: 'corr-123',
      occurred_at: occurredAt.toISOString(),
      payload: { data: 'test' },
    };

    expect(mockChannel.publish).toHaveBeenCalledWith(
      'chorus.events',
      'payment.processed',
      Buffer.from(JSON.stringify(expectedEnvelope)),
      {
        messageId: 'uuid',
        correlationId: 'corr-123',
        contentType: 'application/json',
        timestamp: occurredAt.getTime(),
        persistent: true,
      },
    );
    expect(pendingEvent.status).toBe('PUBLISHED');
    expect(outboxRepository.save).toHaveBeenCalledWith(pendingEvent);
  });
});
