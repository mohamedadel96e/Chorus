package com.example.inventory_service.repository;

import com.example.inventory_service.model.ReservationItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.UUID;

@Repository
public interface ReservationItemRepository extends JpaRepository<ReservationItem, UUID> {
}
