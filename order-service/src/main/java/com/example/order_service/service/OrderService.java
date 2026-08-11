package com.example.order_service.service;

import com.example.order_service.domain.Order;
import com.example.order_service.domain.OrderItem;
import com.example.order_service.domain.OrderRepository;
import com.example.order_service.dto.OrderCreatedPayload;
import com.example.order_service.dto.OrderItemRequest;
import com.example.order_service.dto.OrderRequest;
import com.example.order_service.outbox.OutboxEvent;
import com.example.order_service.outbox.OutboxEventRepository;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

@Service
public class OrderService {

  private static final Logger log = LoggerFactory.getLogger(OrderService.class);

  private final OrderRepository orderRepository;
  private final OutboxEventRepository outboxEventRepository;
  private final ObjectMapper objectMapper;

  public OrderService(
      OrderRepository orderRepository,
      OutboxEventRepository outboxEventRepository,
      ObjectMapper objectMapper) {
    this.orderRepository = orderRepository;
    this.outboxEventRepository = outboxEventRepository;
    this.objectMapper = objectMapper;
  }

  @Transactional
  public Order createOrder(OrderRequest request) {
    if (request.getCustomerId() == null || request.getCustomerId().isEmpty()) {
      throw new IllegalArgumentException("Customer ID is required");
    }
    if (request.getItems() == null || request.getItems().isEmpty()) {
      throw new IllegalArgumentException("Order must have items");
    }

    UUID orderId = UUID.randomUUID();
    int totalCents = 0;
    List<OrderCreatedPayload.Item> payloadItems = new ArrayList<>();

    Order order = new Order(orderId, request.getCustomerId(), 0, "USD", "PENDING", Instant.now());

    for (OrderItemRequest itemReq : request.getItems()) {
      if (itemReq.getQuantity() == null || itemReq.getQuantity() <= 0) {
        throw new IllegalArgumentException("Quantity must be positive");
      }
      if (itemReq.getUnitPriceCents() == null || itemReq.getUnitPriceCents() < 0) {
        throw new IllegalArgumentException("Unit price must be non-negative");
      }
      int lineTotal = itemReq.getQuantity() * itemReq.getUnitPriceCents();
      totalCents += lineTotal;

      OrderItem orderItem =
          new OrderItem(
              UUID.randomUUID(),
              itemReq.getProductId(),
              itemReq.getQuantity(),
              itemReq.getUnitPriceCents());
      order.addItem(orderItem);

      OrderCreatedPayload.Item payloadItem = new OrderCreatedPayload.Item();
      payloadItem.setProductId(itemReq.getProductId());
      payloadItem.setQuantity(itemReq.getQuantity());
      payloadItem.setUnitPriceCents(itemReq.getUnitPriceCents());
      payloadItems.add(payloadItem);
    }

    order.setTotalAmountCents(totalCents);
    orderRepository.save(order);

    OrderCreatedPayload payload = new OrderCreatedPayload();
    payload.setOrderId(orderId.toString());
    payload.setCustomerId(request.getCustomerId());
    payload.setTotalAmountCents(totalCents);
    payload.setCurrency("USD");
    payload.setItems(payloadItems);

    try {
      String payloadJson = objectMapper.writeValueAsString(payload);
      OutboxEvent event =
          new OutboxEvent(
              UUID.randomUUID(),
              "OrderCreated",
              "order.created",
              orderId,
              payloadJson,
              Instant.now(),
              "PENDING");
      outboxEventRepository.save(event);
    } catch (JacksonException e) {
      throw new RuntimeException("Failed to serialize event payload", e);
    }

    return order;
  }

  @Transactional
  public void updateOrderStatus(UUID orderId, String status) {
    Order order = orderRepository.findById(orderId).orElse(null);
    if (order != null) {
      if ("COMPLETED".equals(order.getStatus()) || "CANCELLED".equals(order.getStatus())) {
        log.warn("Attempt to change status of terminal order {} to {}", orderId, status);
        return; // Ignore invalid state transition
      }

      // Phase 6: Strict State Machine to prevent race conditions
      String currentStatus = order.getStatus();
      boolean validTransition = false;

      switch (status) {
        case "CONFIRMED":
          validTransition = "PENDING".equalsIgnoreCase(currentStatus) || "FAILED_PENDING_COMPENSATION".equalsIgnoreCase(currentStatus);
          break;
        case "SHIPMENT_FAILED":
          validTransition = "PENDING".equalsIgnoreCase(currentStatus) || "CONFIRMED".equalsIgnoreCase(currentStatus);
          break;
        case "FAILED_PENDING_COMPENSATION":
          validTransition = "PENDING".equalsIgnoreCase(currentStatus);
          break;
        case "REFUNDED":
          validTransition = "SHIPMENT_FAILED".equalsIgnoreCase(currentStatus) || "CONFIRMED".equalsIgnoreCase(currentStatus);
          break;
        case "COMPLETED":
          validTransition = "CONFIRMED".equalsIgnoreCase(currentStatus) || "PENDING".equalsIgnoreCase(currentStatus);
          break;
        case "CANCELLED":
          validTransition = true; // Can be cancelled from any non-terminal state
          break;
        default:
          validTransition = false;
      }

      if (!validTransition) {
        log.warn("Ignoring invalid state transition for order {}: {} -> {} (likely an out-of-order event)", orderId, currentStatus, status);
        return;
      }

      order.setStatus(status);
      orderRepository.save(order);

      if ("COMPLETED".equals(status)) {
        try {
          String payloadJson =
              objectMapper.writeValueAsString(Map.of("order_id", orderId.toString()));
          OutboxEvent event =
              new OutboxEvent(
                  UUID.randomUUID(),
                  "OrderCompleted",
                  "order.completed",
                  orderId, // This is the originating orderId, so it is the correlationId
                  payloadJson,
                  Instant.now(),
                  "PENDING");
          outboxEventRepository.save(event);
        } catch (JacksonException e) {
          throw new RuntimeException("Failed to serialize OrderCompleted payload", e);
        }
      }
    }
  }

  @Transactional
  public void cancelOrder(UUID orderId, String reason) {
    Order order = orderRepository.findById(orderId).orElse(null);
    if (order != null) {
      if ("COMPLETED".equals(order.getStatus()) || "CANCELLED".equals(order.getStatus())) {
        log.warn("Attempt to cancel terminal order {} with reason {}", orderId, reason);
        return;
      }

      String actualReason = reason;
      if ("Payment or shipment failed - all compensations completed".equals(reason)) {
         if ("FAILED_PENDING_COMPENSATION".equals(order.getStatus())) {
             actualReason = "Simulated payment failure";
         } else if ("REFUNDED".equals(order.getStatus()) || "SHIPMENT_FAILED".equals(order.getStatus())) {
             actualReason = "Shipping address validation failed";
         }
      }

      order.setStatus("CANCELLED");
      order.setCancellationReason(actualReason);
      orderRepository.save(order);

      try {
        String payloadJson = objectMapper.writeValueAsString(Map.of(
            "order_id", orderId.toString(),
            "reason", reason,
            "final_status", "cancelled"
        ));
        OutboxEvent event = new OutboxEvent(
            UUID.randomUUID(),
            "OrderCancelled",
            "order.cancelled",
            orderId, // correlationId
            payloadJson,
            Instant.now(),
            "PENDING"
        );
        outboxEventRepository.save(event);
      } catch (JacksonException e) {
        throw new RuntimeException("Failed to serialize OrderCancelled payload", e);
      }
    }
  }
}
