package com.example.inventory_service.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.util.UUID;

@Entity
@Table(name = "reservation_items")
public class ReservationItem {
  @Id private UUID id;

  @Column(name = "reservation_id")
  private UUID reservationId;

  private String productId;

  private int quantity;

  public ReservationItem() {}

  public ReservationItem(UUID id, UUID reservationId, String productId, int quantity) {
    this.id = id;
    this.reservationId = reservationId;
    this.productId = productId;
    this.quantity = quantity;
  }

  public UUID getId() {
    return id;
  }

  public void setId(UUID id) {
    this.id = id;
  }

  public UUID getReservationId() {
    return reservationId;
  }

  public void setReservationId(UUID reservationId) {
    this.reservationId = reservationId;
  }

  public String getProductId() {
    return productId;
  }

  public void setProductId(String productId) {
    this.productId = productId;
  }

  public int getQuantity() {
    return quantity;
  }

  public void setQuantity(int quantity) {
    this.quantity = quantity;
  }
}
