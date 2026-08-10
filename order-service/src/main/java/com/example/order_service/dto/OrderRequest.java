package com.example.order_service.dto;

import java.util.List;

public class OrderRequest {
  private String customerId;
  private List<OrderItemRequest> items;

  public String getCustomerId() {
    return customerId;
  }

  public void setCustomerId(String customerId) {
    this.customerId = customerId;
  }

  public List<OrderItemRequest> getItems() {
    return items;
  }

  public void setItems(List<OrderItemRequest> items) {
    this.items = items;
  }
}
