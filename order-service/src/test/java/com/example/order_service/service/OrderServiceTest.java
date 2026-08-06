package com.example.order_service.service;

import com.example.order_service.domain.Order;
import com.example.order_service.domain.OrderRepository;
import com.example.order_service.dto.OrderItemRequest;
import com.example.order_service.dto.OrderRequest;
import com.example.order_service.outbox.OutboxEvent;
import com.example.order_service.outbox.OutboxEventRepository;
import tools.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@SpringBootTest
class OrderServiceTest {

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

    @MockitoBean
    private RabbitTemplate rabbitTemplate;

    @Autowired
    private OrderService orderService;

    @Autowired
    private OrderRepository orderRepository;

    @Autowired
    private OutboxEventRepository outboxEventRepository;

    @Test
    void testCreateOrderSuccessfully() {
        OrderRequest req = new OrderRequest();
        req.setCustomerId("42");
        
        OrderItemRequest item = new OrderItemRequest();
        item.setProductId("101");
        item.setQuantity(2);
        item.setUnitPriceCents(1500);
        
        req.setItems(List.of(item));

        Order order = orderService.createOrder(req);

        assertNotNull(order.getId());
        assertEquals("42", order.getCustomerId());
        assertEquals(3000, order.getTotalAmountCents());
        
        List<OutboxEvent> events = outboxEventRepository.findAll();
        // Clear all previous events if there were any, but there should only be 1 for this run
        assertTrue(events.size() > 0);
        
        // Grab the most recently added event
        OutboxEvent event = events.get(events.size() - 1);
        assertEquals("OrderCreated", event.getEventType());
        assertEquals("PENDING", event.getStatus());
        assertTrue(event.getPayload().contains("42"));
        assertTrue(event.getPayload().contains("3000"));
    }
}
