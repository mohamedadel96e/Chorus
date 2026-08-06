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

    const pendingEvent = new OutboxEvent();
    pendingEvent.id = 'uuid';
    pendingEvent.routingKey = 'payment.processed';
    pendingEvent.payload = { data: 'test' };
    pendingEvent.status = 'PENDING';
    pendingEvent.occurredAt = new Date();
    outboxRepository.find.mockResolvedValue([pendingEvent]);

    await service.onModuleInit();
    await service.relayEvents();

    expect(outboxRepository.find).toHaveBeenCalled();
    expect(mockChannel.publish).toHaveBeenCalledWith(
      'chorus.events',
      'payment.processed',
      Buffer.from(JSON.stringify({ data: 'test' })),
      expect.any(Object),
    );
    expect(pendingEvent.status).toBe('PUBLISHED');
    expect(outboxRepository.save).toHaveBeenCalledWith(pendingEvent);
  });
});
