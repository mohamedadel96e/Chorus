package com.example.order_service.domain;

import java.util.List;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;

public interface EventTraceRepository extends JpaRepository<EventTrace, UUID> {
  List<EventTrace> findByCorrelationIdOrderByOccurredAtAsc(String correlationId);
  List<EventTrace> findByEventId(UUID eventId);
}
