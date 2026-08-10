package com.example.order_service.service;

import com.example.order_service.domain.Order;
import com.example.order_service.domain.OrderItem;
import com.example.order_service.domain.OrderRepository;
import com.example.order_service.dto.OrderCreatedPayload;
import com.example.order_service.dto.OrderItemRequest;
import com.example.order_service.dto.OrderRequest;
import com.example.order_service.outbox.OutboxEvent;
import com.example.order_service.outbox.OutboxEventRepository;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.Map;

@Service
public class OrderService {

    private final OrderRepository orderRepository;
    private final OutboxEventRepository outboxEventRepository;
    private final ObjectMapper objectMapper;

    public OrderService(OrderRepository orderRepository, OutboxEventRepository outboxEventRepository,
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

        Order order = new Order(orderId, request.getCustomerId(), 0, "USD", "pending", Instant.now());

        for (OrderItemRequest itemReq : request.getItems()) {
            if (itemReq.getQuantity() == null || itemReq.getQuantity() <= 0) {
                throw new IllegalArgumentException("Quantity must be positive");
            }
            if (itemReq.getUnitPriceCents() == null || itemReq.getUnitPriceCents() < 0) {
                throw new IllegalArgumentException("Unit price must be non-negative");
            }
            int lineTotal = itemReq.getQuantity() * itemReq.getUnitPriceCents();
            totalCents += lineTotal;

            OrderItem orderItem = new OrderItem(UUID.randomUUID(), itemReq.getProductId(), itemReq.getQuantity(),
                    itemReq.getUnitPriceCents());
            order.addItem(orderItem);

            OrderCreatedPayload.Item payloadItem = new OrderCreatedPayload.Item();
            payloadItem.setProduct_id(itemReq.getProductId());
            payloadItem.setQuantity(itemReq.getQuantity());
            payloadItem.setUnit_price_cents(itemReq.getUnitPriceCents());
            payloadItems.add(payloadItem);
        }

        order.setTotalAmountCents(totalCents);
        orderRepository.save(order);

        OrderCreatedPayload payload = new OrderCreatedPayload();
        payload.setOrder_id(orderId.toString());
        payload.setCustomer_id(request.getCustomerId());
        payload.setTotal_amount_cents(totalCents);
        payload.setCurrency("USD");
        payload.setItems(payloadItems);

        try {
            String payloadJson = objectMapper.writeValueAsString(payload);
            OutboxEvent event = new OutboxEvent(
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
            order.setStatus(status);
            orderRepository.save(order);

            if ("COMPLETED".equals(status)) {
                try {
                    String payloadJson = objectMapper.writeValueAsString(Map.of("order_id", orderId.toString()));
                    OutboxEvent event = new OutboxEvent(
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
}
