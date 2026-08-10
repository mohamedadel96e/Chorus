package com.example.inventory_service.outbox;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.eq;

import java.time.Instant;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.testcontainers.containers.PostgreSQLContainer;

@SpringBootTest
class OutboxRelayTest {

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

  @Autowired private OutboxEventRepository outboxEventRepository;

  @Autowired private OutboxRelay outboxRelay;

  @MockitoBean private RabbitTemplate rabbitTemplate;

  @Test
  void testRelayPendingEvents() {
    OutboxEvent event =
        new OutboxEvent(
            UUID.randomUUID(),
            "InventoryUpdated",
            "inventory.updated",
            UUID.randomUUID(),
            "{\"test\":\"data\"}",
            Instant.now(),
            "PENDING");
    outboxEventRepository.save(event);

    outboxRelay.relayEvents();

    Mockito.verify(rabbitTemplate, Mockito.times(1))
        .send(
            eq("chorus.events"),
            eq("inventory.updated"),
            Mockito.any(org.springframework.amqp.core.Message.class));

    OutboxEvent updatedEvent = outboxEventRepository.findById(event.getId()).orElseThrow();
    assertEquals("PUBLISHED", updatedEvent.getStatus());
  }
}
