package com.example.inventory_service.controller;

import com.example.inventory_service.service.InventoryService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/inventory")
public class InventoryController {
    private final InventoryService inventoryService;

    public InventoryController(InventoryService inventoryService) {
        this.inventoryService = inventoryService;
    }

    @PostMapping("/reserve")
    public ResponseEntity<ReserveInventoryResponse> reserve(@RequestBody ReserveInventoryRequest request) {
        try {
            ReserveInventoryResponse response = inventoryService.reserve(request);
            return ResponseEntity.status(HttpStatus.CREATED).body(response);
        } catch (RuntimeException e) {
            ReserveInventoryResponse errorResponse = new ReserveInventoryResponse();
            errorResponse.setStatus("FAILED");
            errorResponse.setMessage(e.getMessage());
            return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(errorResponse);
        }
    }
}
