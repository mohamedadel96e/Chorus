package com.example.order_service.dto;

public class OrderItemRequest {
  private String productId;
  private Integer quantity;
  private Integer unitPriceCents;

  public String getProductId() {
    return productId;
  }

  public void setProductId(String productId) {
    this.productId = productId;
  }

  public Integer getQuantity() {
    return quantity;
  }

  public void setQuantity(Integer quantity) {
    this.quantity = quantity;
  }

  public Integer getUnitPriceCents() {
    return unitPriceCents;
  }

  public void setUnitPriceCents(Integer unitPriceCents) {
    this.unitPriceCents = unitPriceCents;
  }
}
