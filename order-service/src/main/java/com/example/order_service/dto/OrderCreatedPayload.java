package com.example.order_service.dto;

import java.util.List;

public class OrderCreatedPayload {
  private String order_id;
  private String customer_id;
  private List<Item> items;
  private Integer total_amount_cents;
  private String currency;

  public static class Item {
    private String product_id;
    private Integer quantity;
    private Integer unit_price_cents;

    public String getProduct_id() {
      return product_id;
    }

    public void setProduct_id(String product_id) {
      this.product_id = product_id;
    }

    public Integer getQuantity() {
      return quantity;
    }

    public void setQuantity(Integer quantity) {
      this.quantity = quantity;
    }

    public Integer getUnit_price_cents() {
      return unit_price_cents;
    }

    public void setUnit_price_cents(Integer unit_price_cents) {
      this.unit_price_cents = unit_price_cents;
    }
  }

  public String getOrder_id() {
    return order_id;
  }

  public void setOrder_id(String order_id) {
    this.order_id = order_id;
  }

  public String getCustomer_id() {
    return customer_id;
  }

  public void setCustomer_id(String customer_id) {
    this.customer_id = customer_id;
  }

  public List<Item> getItems() {
    return items;
  }

  public void setItems(List<Item> items) {
    this.items = items;
  }

  public Integer getTotal_amount_cents() {
    return total_amount_cents;
  }

  public void setTotal_amount_cents(Integer total_amount_cents) {
    this.total_amount_cents = total_amount_cents;
  }

  public String getCurrency() {
    return currency;
  }

  public void setCurrency(String currency) {
    this.currency = currency;
  }
}
