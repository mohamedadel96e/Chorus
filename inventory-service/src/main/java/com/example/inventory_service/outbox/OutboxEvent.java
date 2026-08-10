package com.example.inventory_service.outbox;

import jakarta.persistence.*;
import java.time.Instant;
import java.util.UUID;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

@Entity
@Table(name = "outbox_events")
public class OutboxEvent {

  @Id private UUID id;

  @Column(name = "event_type", nullable = false)
  private String eventType;

  @Column(name = "routing_key", nullable = false)
  private String routingKey;

  @Column(name = "correlation_id", nullable = false)
  private UUID correlationId;

  @JdbcTypeCode(SqlTypes.JSON)
  @Column(name = "payload", nullable = false, columnDefinition = "jsonb")
  private String payload;

  @Column(name = "occurred_at", nullable = false)
  private Instant occurredAt;

  @Column(name = "status", nullable = false)
  private String status;

  public OutboxEvent() {}

  public OutboxEvent(
      UUID id,
      String eventType,
      String routingKey,
      UUID correlationId,
      String payload,
      Instant occurredAt,
      String status) {
    this.id = id;
    this.eventType = eventType;
    this.routingKey = routingKey;
    this.correlationId = correlationId;
    this.payload = payload;
    this.occurredAt = occurredAt;
    this.status = status;
  }

  public UUID getId() {
    return id;
  }

  public void setId(UUID id) {
    this.id = id;
  }

  public String getEventType() {
    return eventType;
  }

  public void setEventType(String eventType) {
    this.eventType = eventType;
  }

  public String getRoutingKey() {
    return routingKey;
  }

  public void setRoutingKey(String routingKey) {
    this.routingKey = routingKey;
  }

  public UUID getCorrelationId() {
    return correlationId;
  }

  public void setCorrelationId(UUID correlationId) {
    this.correlationId = correlationId;
  }

  public String getPayload() {
    return payload;
  }

  public void setPayload(String payload) {
    this.payload = payload;
  }

  public Instant getOccurredAt() {
    return occurredAt;
  }

  public void setOccurredAt(Instant occurredAt) {
    this.occurredAt = occurredAt;
  }

  public String getStatus() {
    return status;
  }

  public void setStatus(String status) {
    this.status = status;
  }
}
