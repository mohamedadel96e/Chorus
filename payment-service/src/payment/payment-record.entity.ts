import { Entity, Column, PrimaryGeneratedColumn, CreateDateColumn } from 'typeorm';

@Entity('payments')
export class PaymentRecord {
  @PrimaryGeneratedColumn('uuid')
  id: string;

  @Column('uuid')
  orderId: string;

  @Column('int')
  amountCents: number;

  @Column()
  currency: string;

  @Column()
  status: string; // PENDING, SUCCESS, FAILED

  @CreateDateColumn()
  createdAt: Date;
}
