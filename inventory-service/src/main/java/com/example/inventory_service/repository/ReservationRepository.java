package com.example.inventory_service.repository;

import com.example.inventory_service.model.Reservation;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.UUID;

@Repository
public interface ReservationRepository extends JpaRepository<Reservation, UUID> {
    Reservation findByOrderId(UUID orderId);
}
