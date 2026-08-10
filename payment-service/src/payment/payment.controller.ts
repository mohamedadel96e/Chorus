import { Controller, Post, Body, NotImplementedException } from '@nestjs/common';
import { PaymentService } from './payment.service';

@Controller('api/payment')
export class PaymentController {
  constructor(private readonly paymentService: PaymentService) {}

  @Post('charge')
  async charge(@Body() request: any) {
    throw new NotImplementedException(
      'Synchronous charging is not supported. Use RabbitMQ events (inventory.reserved) instead.',
    );
  }
}
