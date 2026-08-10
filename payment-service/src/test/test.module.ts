import { Module } from '@nestjs/common';
import { TestService } from './test.service';
import { TestResolver } from './test.resolver';

@Module({
  providers: [TestResolver, TestService],
})
export class TestModule {}
