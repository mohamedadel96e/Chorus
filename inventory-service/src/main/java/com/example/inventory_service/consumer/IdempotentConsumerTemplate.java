package com.example.inventory_service.consumer;

import com.example.inventory_service.outbox.ProcessedEvent;
import com.example.inventory_service.outbox.ProcessedEventRepository;
import java.time.Instant;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
public class IdempotentConsumerTemplate {

  private static final Logger log = LoggerFactory.getLogger(IdempotentConsumerTemplate.class);
  private final ProcessedEventRepository processedEventRepository;

  public IdempotentConsumerTemplate(ProcessedEventRepository processedEventRepository) {
    this.processedEventRepository = processedEventRepository;
  }

  @Transactional
  public void process(UUID eventId, Runnable businessLogic) {
    try {
      ProcessedEvent processedEvent = new ProcessedEvent(eventId, Instant.now());
      processedEventRepository.saveAndFlush(processedEvent);
    } catch (DataIntegrityViolationException e) {
      log.warn(
          "Duplicate event detected: {}. Skipping execution to maintain idempotency.", eventId);
      return;
    }

    businessLogic.run();
  }
}
