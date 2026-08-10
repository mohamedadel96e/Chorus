package com.example.inventory_service.service;

import static org.junit.jupiter.api.Assertions.*;

import com.example.inventory_service.controller.ReserveInventoryRequest;
import com.example.inventory_service.controller.ReserveInventoryResponse;
import com.example.inventory_service.model.Product;
import com.example.inventory_service.outbox.OutboxEvent;
import com.example.inventory_service.outbox.OutboxEventRepository;
import com.example.inventory_service.repository.ProductRepository;
import com.example.inventory_service.repository.ReservationItemRepository;
import com.example.inventory_service.repository.ReservationRepository;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

@SpringBootTest
class InventoryServiceTest {

  static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

  static {
    postgres.start();
  }

  @DynamicPropertySource
  static void configureProperties(DynamicPropertyRegistry registry) {
    registry.add("spring.datasource.url", postgres::getJdbcUrl);
    registry.add("spring.datasource.username", postgres::getUsername);
    registry.add("spring.datasource.password", postgres::getPassword);
    registry.add("spring.jpa.hibernate.ddl-auto", () -> "update");
  }

  @Autowired private InventoryService inventoryService;

  @Autowired private ProductRepository productRepository;

  @Autowired private ReservationRepository reservationRepository;

  @Autowired private ReservationItemRepository reservationItemRepository;

  @Autowired private OutboxEventRepository outboxEventRepository;

  @BeforeEach
  void setUp() {
    outboxEventRepository.deleteAll();
    reservationItemRepository.deleteAll();
    reservationRepository.deleteAll();
    productRepository.deleteAll();

    productRepository.save(new Product("P123", 100));
  }

  @Test
  void testReserveInventory_Success() {
    ReserveInventoryRequest request = new ReserveInventoryRequest();
    request.setOrderId(UUID.randomUUID());
    ReserveInventoryRequest.Item item = new ReserveInventoryRequest.Item();
    item.setProductId("P123");
    item.setQuantity(2);
    request.setItems(Collections.singletonList(item));

    ReserveInventoryResponse response = inventoryService.reserve(request);

    assertEquals("CONFIRMED", response.getStatus());
    assertNotNull(response.getReservationId());

    Product product = productRepository.findById("P123").orElseThrow();
    assertEquals(98, product.getAvailableQuantity());

    List<OutboxEvent> events = outboxEventRepository.findAll();
    assertEquals(1, events.size());
    OutboxEvent event = events.get(0);
    assertEquals("InventoryReserved", event.getEventType());
    assertEquals("PENDING", event.getStatus());
    assertTrue(event.getPayload().contains("CONFIRMED"));
  }

  @Test
  void testReserveInventory_InsufficientStock() {
    ReserveInventoryRequest request = new ReserveInventoryRequest();
    request.setOrderId(UUID.randomUUID());
    ReserveInventoryRequest.Item item = new ReserveInventoryRequest.Item();
    item.setProductId("P123");
    item.setQuantity(200); // More than available 100
    request.setItems(Collections.singletonList(item));

    assertThrows(
        RuntimeException.class,
        () -> {
          inventoryService.reserve(request);
        });

    Product product = productRepository.findById("P123").orElseThrow();
    assertEquals(100, product.getAvailableQuantity()); // Stock unchanged

    assertEquals(0, reservationRepository.count());
    assertEquals(0, outboxEventRepository.count());
  }
}
