import { Entity, Column, PrimaryColumn } from 'typeorm';

@Entity('outbox_events')
export class OutboxEvent {
  @PrimaryColumn('uuid')
  id: string;

  @Column({ name: 'event_type' })
  eventType: string;

  @Column({ name: 'routing_key' })
  routingKey: string;

  @Column({ name: 'correlation_id', type: 'uuid' })
  correlationId: string;

  @Column({ type: 'jsonb' })
  payload: any;

  @Column({ name: 'occurred_at', type: 'timestamp' })
  occurredAt: Date;

  @Column()
  status: string;
}
