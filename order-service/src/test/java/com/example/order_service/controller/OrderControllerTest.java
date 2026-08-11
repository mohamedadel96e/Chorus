package com.example.order_service.controller;

import static org.mockito.ArgumentMatchers.any;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.order_service.domain.Order;
import com.example.order_service.dto.OrderItemRequest;
import com.example.order_service.dto.OrderRequest;
import com.example.order_service.service.OrderService;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import tools.jackson.databind.ObjectMapper;

class OrderControllerTest {

  private MockMvc mockMvc;
  private OrderService orderService;
  private OrderController orderController;
  private ObjectMapper objectMapper = new ObjectMapper();

  @BeforeEach
  void setUp() {
    orderService = Mockito.mock(OrderService.class);
    com.example.order_service.domain.OrderRepository orderRepository = Mockito.mock(com.example.order_service.domain.OrderRepository.class);
    com.example.order_service.domain.EventTraceRepository eventTraceRepository = Mockito.mock(com.example.order_service.domain.EventTraceRepository.class);
    orderController = new OrderController(orderService, orderRepository, eventTraceRepository);
    mockMvc = MockMvcBuilders.standaloneSetup(orderController).build();
  }

  @Test
  void createOrder_ReturnsCreatedOrder() throws Exception {
    OrderRequest request = new OrderRequest();
    request.setCustomerId("42");
    OrderItemRequest item = new OrderItemRequest();
    item.setProductId("101");
    item.setQuantity(2);
    item.setUnitPriceCents(1500);
    request.setItems(List.of(item));

    UUID orderId = UUID.randomUUID();
    Order order = new Order(orderId, "42", 3000, "USD", "PENDING", Instant.now());

    Mockito.when(orderService.createOrder(any(OrderRequest.class))).thenReturn(order);

    mockMvc
        .perform(
            post("/api/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(request)))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.orderId").value(orderId.toString()))
        .andExpect(jsonPath("$.status").value("PENDING"));
  }
}
