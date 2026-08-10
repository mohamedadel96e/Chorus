package com.example.inventory_service.controller;

import java.util.UUID;

public class ReserveInventoryResponse {
    private UUID reservationId;
    private String status;
    private String message;

    public ReserveInventoryResponse() {
    }

    public ReserveInventoryResponse(UUID reservationId, String status, String message) {
        this.reservationId = reservationId;
        this.status = status;
        this.message = message;
    }

    public UUID getReservationId() {
        return reservationId;
    }

    public void setReservationId(UUID reservationId) {
        this.reservationId = reservationId;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public String getMessage() {
        return message;
    }

    public void setMessage(String message) {
        this.message = message;
    }
}
