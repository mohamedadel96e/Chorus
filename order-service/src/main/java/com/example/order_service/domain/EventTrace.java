package com.example.order_service.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;
import java.util.UUID;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

@Entity
@Table(name = "event_trace")
public class EventTrace {

  @Id private UUID id;

  @Column(name = "correlation_id", nullable = false)
  private String correlationId;

  @Column(name = "event_id", nullable = false)
  private UUID eventId;

  @Column(name = "event_type", nullable = false)
  private String eventType;

  @JdbcTypeCode(SqlTypes.JSON)
  @Column(name = "payload", columnDefinition = "jsonb", nullable = false)
  private String payload;

  @Column(name = "occurred_at", nullable = false)
  private Instant occurredAt;

  @Column(name = "recorded_at", nullable = false)
  private Instant recordedAt;

  protected EventTrace() {}

  public EventTrace(
      UUID id,
      String correlationId,
      UUID eventId,
      String eventType,
      String payload,
      Instant occurredAt) {
    this.id = id;
    this.correlationId = correlationId;
    this.eventId = eventId;
    this.eventType = eventType;
    this.payload = payload;
    this.occurredAt = occurredAt;
    this.recordedAt = Instant.now();
  }

  public UUID getId() {
    return id;
  }

  public String getCorrelationId() {
    return correlationId;
  }

  public UUID getEventId() {
    return eventId;
  }

  public String getEventType() {
    return eventType;
  }

  public String getPayload() {
    return payload;
  }

  public Instant getOccurredAt() {
    return occurredAt;
  }

  public Instant getRecordedAt() {
    return recordedAt;
  }
}
