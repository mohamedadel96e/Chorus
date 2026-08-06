import { Test, TestingModule } from '@nestjs/testing';
import { PaymentController } from './payment.controller';
import { PaymentService } from './payment.service';

describe('PaymentController', () => {
  let controller: PaymentController;
  let service: PaymentService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [PaymentController],
      providers: [
        {
          provide: PaymentService,
          useValue: {
            charge: jest.fn().mockResolvedValue({
              paymentId: 'payment-id-123',
              status: 'SUCCESS',
              message: 'Payment charged successfully',
            }),
          },
        },
      ],
    }).compile();

    controller = module.get<PaymentController>(PaymentController);
    service = module.get<PaymentService>(PaymentService);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  it('should call paymentService.charge', async () => {
    const request = {
      orderId: 'order-123',
      amountCents: 1000,
      currency: 'USD',
    };

    const response = await controller.charge(request);

    expect(service.charge).toHaveBeenCalledWith(request);
    expect(response).toEqual({
      paymentId: 'payment-id-123',
      status: 'SUCCESS',
      message: 'Payment charged successfully',
    });
  });
});
