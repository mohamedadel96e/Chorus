package com.example.order_service.dto;

import java.util.List;
import com.fasterxml.jackson.annotation.JsonProperty;

public class OrderCreatedPayload {
  @JsonProperty("order_id")
  private String orderId;

  @JsonProperty("customer_id")
  private String customerId;

  private List<Item> items;

  @JsonProperty("total_amount_cents")
  private Integer totalAmountCents;

  private String currency;

  public static class Item {
    @JsonProperty("product_id")
    private String productId;

    private Integer quantity;

    @JsonProperty("unit_price_cents")
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

  public String getOrderId() {
    return orderId;
  }

  public void setOrderId(String orderId) {
    this.orderId = orderId;
  }

  public String getCustomerId() {
    return customerId;
  }

  public void setCustomerId(String customerId) {
    this.customerId = customerId;
  }

  public List<Item> getItems() {
    return items;
  }

  public void setItems(List<Item> items) {
    this.items = items;
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

  public void setCurrency(String currency) {
    this.currency = currency;
  }
}
