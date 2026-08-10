package com.example.order_service.controller;

import com.example.order_service.domain.Order;
import com.example.order_service.dto.OrderRequest;
import com.example.order_service.service.OrderService;
import java.util.HashMap;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

  private final OrderService orderService;

  public OrderController(OrderService orderService) {
    this.orderService = orderService;
  }

  @PostMapping
  public ResponseEntity<?> createOrder(@RequestBody OrderRequest request) {
    try {
      Order order = orderService.createOrder(request);
      Map<String, Object> response = new HashMap<>();
      response.put("orderId", order.getId());
      response.put("status", order.getStatus());
      return ResponseEntity.status(HttpStatus.CREATED).body(response);
    } catch (IllegalArgumentException e) {
      Map<String, String> error = new HashMap<>();
      error.put("error", e.getMessage());
      return ResponseEntity.badRequest().body(error);
    } catch (Exception e) {
      Map<String, String> error = new HashMap<>();
      error.put("error", "Internal server error");
      return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(error);
    }
  }
}
