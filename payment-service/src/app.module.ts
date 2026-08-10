import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ScheduleModule } from '@nestjs/schedule';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { OutboxModule } from './outbox/outbox.module';
import { OutboxEvent } from './outbox/outbox-event.entity';
import { ProcessedEvent } from './outbox/processed-event.entity';
import { PaymentModule } from './payment/payment.module';
import { PaymentRecord } from './payment/payment-record.entity';
import { ConsumerModule } from './consumer/consumer.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
    }),
    TypeOrmModule.forRootAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        type: 'postgres',
        host: configService.get<string>('DB_HOST') || 'localhost',
        port: configService.get<number>('DB_PORT') || 5432,
        username: configService.get<string>('DB_USER') || 'postgres',
        password: configService.get<string>('DB_PASSWORD') || 'password',
        database: configService.get<string>('DB_NAME') || 'payment_db',
        entities: [OutboxEvent, ProcessedEvent, PaymentRecord],
        synchronize: true, // Use only in development
      }),
    }),
    ScheduleModule.forRoot(),
    OutboxModule,
    PaymentModule,
    ConsumerModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
