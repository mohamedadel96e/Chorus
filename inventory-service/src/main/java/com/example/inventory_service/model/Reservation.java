package com.example.inventory_service.model;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "reservations")
public class Reservation {
  @Id private UUID id;

  private UUID orderId;

  private String status; // PENDING, CONFIRMED, CANCELLED

  private Instant reservedAt;

  public Reservation() {}

  public Reservation(UUID id, UUID orderId, String status, Instant reservedAt) {
    this.id = id;
    this.orderId = orderId;
    this.status = status;
    this.reservedAt = reservedAt;
  }

  public UUID getId() {
    return id;
  }

  public void setId(UUID id) {
    this.id = id;
  }

  public UUID getOrderId() {
    return orderId;
  }

  public void setOrderId(UUID orderId) {
    this.orderId = orderId;
  }

  public String getStatus() {
    return status;
  }

  public void setStatus(String status) {
    this.status = status;
  }

  public Instant getReservedAt() {
    return reservedAt;
  }

  public void setReservedAt(Instant reservedAt) {
    this.reservedAt = reservedAt;
  }
}
