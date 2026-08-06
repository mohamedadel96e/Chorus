package com.example.order_service.domain;

import jakarta.persistence.*;
import java.util.UUID;

@Entity
@Table(name = "order_items")
public class OrderItem {

    @Id
    private UUID id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "order_id", nullable = false)
    private Order order;

    @Column(name = "product_id", nullable = false)
    private String productId;

    @Column(name = "quantity", nullable = false)
    private Integer quantity;

    @Column(name = "unit_price_cents", nullable = false)
    private Integer unitPriceCents;

    protected OrderItem() {
    }

    public OrderItem(UUID id, String productId, Integer quantity, Integer unitPriceCents) {
        this.id = id;
        this.productId = productId;
        this.quantity = quantity;
        this.unitPriceCents = unitPriceCents;
    }

    public void setOrder(Order order) {
        this.order = order;
    }

    public UUID getId() { return id; }
    public Order getOrder() { return order; }
    public String getProductId() { return productId; }
    public Integer getQuantity() { return quantity; }
    public Integer getUnitPriceCents() { return unitPriceCents; }
}
