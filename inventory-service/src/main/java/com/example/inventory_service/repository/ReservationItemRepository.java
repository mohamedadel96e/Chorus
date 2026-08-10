package com.example.inventory_service.repository;

import com.example.inventory_service.model.ReservationItem;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface ReservationItemRepository extends JpaRepository<ReservationItem, UUID> {
  java.util.List<ReservationItem> findByReservationId(UUID reservationId);
}
