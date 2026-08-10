package com.example.inventory_service.controller;

import static org.mockito.ArgumentMatchers.any;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.example.inventory_service.service.InventoryService;
import java.util.Collections;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import tools.jackson.databind.ObjectMapper;

class InventoryControllerTest {

  private MockMvc mockMvc;
  private InventoryService inventoryService;
  private ObjectMapper objectMapper = new ObjectMapper();

  @BeforeEach
  void setUp() {
    inventoryService = Mockito.mock(InventoryService.class);
    InventoryController controller = new InventoryController(inventoryService);
    mockMvc = MockMvcBuilders.standaloneSetup(controller).build();
  }

  @Test
  void testReserve_Success() throws Exception {
    UUID orderId = UUID.randomUUID();
    UUID reservationId = UUID.randomUUID();

    ReserveInventoryRequest request = new ReserveInventoryRequest();
    request.setOrderId(orderId);
    ReserveInventoryRequest.Item item = new ReserveInventoryRequest.Item();
    item.setProductId("P123");
    item.setQuantity(2);
    request.setItems(Collections.singletonList(item));

    ReserveInventoryResponse response =
        new ReserveInventoryResponse(reservationId, "CONFIRMED", "Inventory reserved successfully");
    Mockito.when(inventoryService.reserve(any(ReserveInventoryRequest.class))).thenReturn(response);

    mockMvc
        .perform(
            post("/api/inventory/reserve")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(request)))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.reservationId").value(reservationId.toString()))
        .andExpect(jsonPath("$.status").value("CONFIRMED"));
  }

  @Test
  void testReserve_InsufficientStock() throws Exception {
    UUID orderId = UUID.randomUUID();

    ReserveInventoryRequest request = new ReserveInventoryRequest();
    request.setOrderId(orderId);
    ReserveInventoryRequest.Item item = new ReserveInventoryRequest.Item();
    item.setProductId("P123");
    item.setQuantity(200);
    request.setItems(Collections.singletonList(item));

    Mockito.when(inventoryService.reserve(any(ReserveInventoryRequest.class)))
        .thenThrow(new RuntimeException("Insufficient inventory for product: P123"));

    mockMvc
        .perform(
            post("/api/inventory/reserve")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(request)))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.status").value("FAILED"))
        .andExpect(jsonPath("$.message").value("Insufficient inventory for product: P123"));
  }
}
