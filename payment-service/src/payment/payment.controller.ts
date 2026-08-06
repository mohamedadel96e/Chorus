import { Controller, Post, Body } from '@nestjs/common';
import { PaymentService } from './payment.service';
import type { ChargeRequest } from './payment.service';

@Controller('api/payment')
export class PaymentController {
  constructor(private readonly paymentService: PaymentService) {}

  @Post('charge')
  async charge(@Body() request: ChargeRequest) {
    return await this.paymentService.charge(request);
  }
}
