package com.example.inventory_service.service;

import com.example.inventory_service.controller.ReserveInventoryRequest;
import com.example.inventory_service.controller.ReserveInventoryResponse;
import com.example.inventory_service.model.Product;
import com.example.inventory_service.model.Reservation;
import com.example.inventory_service.model.ReservationItem;
import com.example.inventory_service.repository.ProductRepository;
import com.example.inventory_service.repository.ReservationItemRepository;
import com.example.inventory_service.repository.ReservationRepository;
import com.example.inventory_service.outbox.OutboxEvent;
import com.example.inventory_service.outbox.OutboxEventRepository;

import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;
import java.util.HashMap;
import java.util.Map;

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
        UUID reservationId = UUID.randomUUID();
        
        Reservation reservation = new Reservation(reservationId, request.getOrderId(), "PENDING", Instant.now());
        reservationRepository.save(reservation);

        for (ReserveInventoryRequest.Item reqItem : request.getItems()) {
            Product product = productRepository.findByIdWithPessimisticLock(reqItem.getProductId())
                    .orElseThrow(() -> new RuntimeException("Product not found: " + reqItem.getProductId()));
            
            if (product.getAvailableQuantity() < reqItem.getQuantity()) {
                throw new RuntimeException("Insufficient inventory for product: " + reqItem.getProductId());
            }

            product.setAvailableQuantity(product.getAvailableQuantity() - reqItem.getQuantity());
            productRepository.save(product);

            ReservationItem item = new ReservationItem(UUID.randomUUID(), reservationId, reqItem.getProductId(), reqItem.getQuantity());
            reservationItemRepository.save(item);
        }
        
        reservation.setStatus("CONFIRMED");
        reservationRepository.save(reservation);

        try {
            Map<String, Object> payload = new HashMap<>();
            payload.put("reservationId", reservationId.toString());
            payload.put("orderId", request.getOrderId().toString());
            payload.put("status", "CONFIRMED");
            
            OutboxEvent outboxEvent = new OutboxEvent(
                    UUID.randomUUID(),
                    "InventoryReserved",
                    "inventory.reserved",
                    request.getOrderId(),
                    objectMapper.writeValueAsString(payload),
                    Instant.now(),
                    "PENDING"
            );
            outboxEventRepository.save(outboxEvent);
        } catch (JacksonException e) {
            throw new RuntimeException("Failed to serialize OutboxEvent payload", e);
        }

        return new ReserveInventoryResponse(reservationId, "CONFIRMED", "Inventory reserved successfully");
    }
}
