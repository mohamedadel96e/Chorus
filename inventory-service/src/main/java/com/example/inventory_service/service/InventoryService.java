package com.example.inventory_service.service;

import com.example.inventory_service.model.Product;
import com.example.inventory_service.model.Reservation;
import com.example.inventory_service.model.ReservationItem;
import com.example.inventory_service.repository.ProductRepository;
import com.example.inventory_service.repository.ReservationItemRepository;
import com.example.inventory_service.repository.ReservationRepository;
import com.example.inventory_service.outbox.OutboxEvent;
import com.example.inventory_service.outbox.OutboxEventRepository;
import com.example.inventory_service.controller.ReserveInventoryRequest;
import com.example.inventory_service.controller.ReserveInventoryResponse;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;
import java.util.ArrayList;
import java.util.List;

@Service
public class InventoryService {
    private final ProductRepository productRepository;
    private final ReservationRepository reservationRepository;
    private final ReservationItemRepository reservationItemRepository;
    private final OutboxEventRepository outboxEventRepository;
    private final ObjectMapper objectMapper;

    public InventoryService(ProductRepository productRepository,
            ReservationRepository reservationRepository,
            ReservationItemRepository reservationItemRepository,
            OutboxEventRepository outboxEventRepository,
            ObjectMapper objectMapper) {
        this.productRepository = productRepository;
        this.reservationRepository = reservationRepository;
        this.reservationItemRepository = reservationItemRepository;
        this.outboxEventRepository = outboxEventRepository;
        this.objectMapper = objectMapper;
    }

    @Transactional
    public ReserveInventoryResponse reserve(ReserveInventoryRequest request) {
        throw new UnsupportedOperationException(
                "Synchronous reservation is not supported in this event-driven architecture. Use RabbitMQ events (order.created) instead.");
    }

    @Transactional
    public void processOrderCreated(JsonNode payload, String correlationId) {
        UUID orderId = UUID.fromString(payload.get("order_id").asText());
        ArrayNode items = (ArrayNode) payload.get("items");

        List<ReservationItem> reservationItems = new ArrayList<>();
        List<Product> productsToSave = new ArrayList<>();
        List<ObjectNode> failedItems = new ArrayList<>();
        UUID reservationId = UUID.randomUUID();

        // 1. Check stock and decrement (optimistic locking implicitly applied on save)
        for (JsonNode itemNode : items) {
            String productId = itemNode.get("product_id").asText();
            int quantity = itemNode.get("quantity").asInt();

            Product product = productRepository.findById(productId).orElse(null);

            if (product == null || product.getAvailableQuantity() < quantity) {
                ObjectNode failedItem = objectMapper.createObjectNode();
                failedItem.put("product_id", productId);
                failedItem.put("requested_quantity", quantity);
                failedItem.put("available_quantity", product == null ? 0 : product.getAvailableQuantity());
                failedItems.add(failedItem);
            } else {
                product.setAvailableQuantity(product.getAvailableQuantity() - quantity);
                productsToSave.add(product);
                reservationItems.add(new ReservationItem(UUID.randomUUID(), reservationId, productId, quantity));
            }
        }

        try {
            if (!failedItems.isEmpty()) {
                // Failure path: Insert InventoryReservationFailed
                ObjectNode failedPayload = objectMapper.createObjectNode();
                failedPayload.put("order_id", orderId.toString());
                failedPayload.put("reason", "Insufficient stock for one or more items");
                ArrayNode failedItemsArray = failedPayload.putArray("items");
                failedItems.forEach(failedItemsArray::add);

                OutboxEvent outboxEvent = new OutboxEvent(
                        UUID.randomUUID(),
                        "InventoryReservationFailed",
                        "inventory.reservation_failed",
                        UUID.fromString(correlationId),
                        objectMapper.writeValueAsString(failedPayload),
                        Instant.now(),
                        "PENDING");
                outboxEventRepository.save(outboxEvent);
            } else {
                // Success path: Save decremented stock and reservations
                productRepository.saveAll(productsToSave);

                Reservation reservation = new Reservation(reservationId, orderId, "CONFIRMED", Instant.now());
                reservationRepository.save(reservation);
                reservationItemRepository.saveAll(reservationItems);

                // Fat Event: Forward order details (amount, currency) for Payment Service
                ObjectNode successPayload = objectMapper.createObjectNode();
                successPayload.put("order_id", orderId.toString());
                successPayload.put("reservation_id", reservationId.toString());
                successPayload.set("items", items); // copy original items

                OutboxEvent outboxEvent = new OutboxEvent(
                        UUID.randomUUID(),
                        "InventoryReserved",
                        "inventory.reserved",
                        UUID.fromString(correlationId),
                        objectMapper.writeValueAsString(successPayload),
                        Instant.now(),
                        "PENDING");
                outboxEventRepository.save(outboxEvent);
            }
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize OutboxEvent payload", e);
        }
    }

    @Transactional
    public void processPaymentFailedOrRefunded(JsonNode payload, String correlationId) {
        UUID orderId = UUID.fromString(payload.get("order_id").asText());

        Reservation reservation = reservationRepository.findByOrderId(orderId);
        if (reservation == null || !"CONFIRMED".equals(reservation.getStatus())) {
            // Nothing to release
            return;
        }

        List<ReservationItem> items = reservationItemRepository.findByReservationId(reservation.getId());
        ArrayNode itemsArray = objectMapper.createArrayNode();

        for (ReservationItem item : items) {
            Product product = productRepository.findById(item.getProductId()).orElse(null);
            if (product != null) {
                product.setAvailableQuantity(product.getAvailableQuantity() + item.getQuantity());
                productRepository.save(product);
            }

            ObjectNode itemNode = objectMapper.createObjectNode();
            itemNode.put("product_id", item.getProductId());
            itemNode.put("quantity", item.getQuantity());
            itemsArray.add(itemNode);
        }

        reservation.setStatus("RELEASED");
        reservationRepository.save(reservation);

        try {
            ObjectNode releasePayload = objectMapper.createObjectNode();
            releasePayload.put("order_id", orderId.toString());
            releasePayload.put("reservation_id", reservation.getId().toString());
            releasePayload.set("items", itemsArray);
            releasePayload.put("reason", "Payment failed or refunded - releasing reserved stock");

            OutboxEvent outboxEvent = new OutboxEvent(
                    UUID.randomUUID(),
                    "InventoryReleased",
                    "inventory.released",
                    UUID.fromString(correlationId),
                    objectMapper.writeValueAsString(releasePayload),
                    Instant.now(),
                    "PENDING");
            outboxEventRepository.save(outboxEvent);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize OutboxEvent payload", e);
        }
    }
}
