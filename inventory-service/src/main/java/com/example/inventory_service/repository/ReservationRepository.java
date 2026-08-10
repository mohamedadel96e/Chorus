package com.example.inventory_service.repository;

import com.example.inventory_service.model.Reservation;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface ReservationRepository extends JpaRepository<Reservation, UUID> {
  Reservation findByOrderId(UUID orderId);
}
