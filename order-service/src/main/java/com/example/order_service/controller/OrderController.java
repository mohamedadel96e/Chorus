package com.example.order_service.controller;

import com.example.order_service.domain.EventTrace;
import com.example.order_service.domain.EventTraceRepository;
import com.example.order_service.domain.Order;
import com.example.order_service.domain.OrderRepository;
import com.example.order_service.dto.OrderRequest;
import com.example.order_service.service.OrderService;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

  private final OrderService orderService;
  private final OrderRepository orderRepository;
  private final EventTraceRepository eventTraceRepository;

  public OrderController(OrderService orderService, OrderRepository orderRepository, EventTraceRepository eventTraceRepository) {
    this.orderService = orderService;
    this.orderRepository = orderRepository;
    this.eventTraceRepository = eventTraceRepository;
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

  @GetMapping("/{id}")
  public ResponseEntity<Order> getOrder(@PathVariable UUID id) {
    return orderRepository.findById(id).map(ResponseEntity::ok).orElse(ResponseEntity.notFound().build());
  }

  @GetMapping("/{id}/trace")
  public ResponseEntity<List<EventTrace>> getOrderTrace(@PathVariable UUID id) {
    List<EventTrace> trace = eventTraceRepository.findByCorrelationIdOrderByOccurredAtAsc(id.toString());
    return ResponseEntity.ok(trace);
  }
}
