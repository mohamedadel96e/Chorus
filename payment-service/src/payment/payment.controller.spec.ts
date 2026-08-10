import { Test, TestingModule } from '@nestjs/testing';
import { PaymentController } from './payment.controller';
import { PaymentService } from './payment.service';
import { NotImplementedException } from '@nestjs/common';

describe('PaymentController', () => {
  let controller: PaymentController;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [PaymentController],
      providers: [
        {
          provide: PaymentService,
          useValue: {},
        },
      ],
    }).compile();

    controller = module.get<PaymentController>(PaymentController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  it('should throw NotImplementedException on charge', async () => {
    const request = {
      orderId: 'order-123',
      amountCents: 1000,
      currency: 'USD',
    };

    await expect(controller.charge(request)).rejects.toThrow(
      new NotImplementedException('Synchronous charging is not supported. Use RabbitMQ events (inventory.reserved) instead.'),
    );
  });
});
