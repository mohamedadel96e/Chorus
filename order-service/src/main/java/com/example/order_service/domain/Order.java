package com.example.order_service.domain;

import jakarta.persistence.*;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

@Entity
@Table(name = "orders")
public class Order {

  @Id private UUID id;

  @Column(name = "customer_id", nullable = false)
  private String customerId;

  @Column(name = "total_amount_cents", nullable = false)
  private Integer totalAmountCents;

  @Column(name = "currency", nullable = false)
  private String currency;

  @Column(name = "status", nullable = false)
  private String status;

  @Column(name = "created_at", nullable = false)
  private Instant createdAt;

  @OneToMany(mappedBy = "order", cascade = CascadeType.ALL, orphanRemoval = true)
  private List<OrderItem> items = new ArrayList<>();

  protected Order() {}

  public Order(
      UUID id,
      String customerId,
      Integer totalAmountCents,
      String currency,
      String status,
      Instant createdAt) {
    this.id = id;
    this.customerId = customerId;
    this.totalAmountCents = totalAmountCents;
    this.currency = currency;
    this.status = status;
    this.createdAt = createdAt;
  }

  public void addItem(OrderItem item) {
    items.add(item);
    item.setOrder(this);
  }

  public UUID getId() {
    return id;
  }

  public String getCustomerId() {
    return customerId;
  }

  public Integer getTotalAmountCents() {
    return totalAmountCents;
  }

  public void setTotalAmountCents(Integer totalAmountCents) {
    this.totalAmountCents = totalAmountCents;
  }

  public String getCurrency() {
    return currency;
  }

  public String getStatus() {
    return status;
  }

  public void setStatus(String status) {
    this.status = status;
  }

  public Instant getCreatedAt() {
    return createdAt;
  }

  public List<OrderItem> getItems() {
    return items;
  }
}
