package com.example.inventory_service.consumer;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

import com.example.inventory_service.outbox.ProcessedEvent;
import com.example.inventory_service.outbox.ProcessedEventRepository;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;

class IdempotentConsumerTemplateTest {

  private ProcessedEventRepository repository;
  private IdempotentConsumerTemplate template;

  @BeforeEach
  void setUp() {
    repository = mock(ProcessedEventRepository.class);
    template = new IdempotentConsumerTemplate(repository);
  }

  @Test
  void process_shouldExecuteLogic_whenEventIsNew() {
    UUID eventId = UUID.randomUUID();
    Runnable logic = mock(Runnable.class);

    template.process(eventId, logic);

    verify(repository, times(1)).saveAndFlush(any(ProcessedEvent.class));
    verify(logic, times(1)).run();
  }

  @Test
  void process_shouldSkipLogic_whenEventIsDuplicate() {
    UUID eventId = UUID.randomUUID();
    Runnable logic = mock(Runnable.class);

    doThrow(new DataIntegrityViolationException("Duplicate key"))
        .when(repository)
        .saveAndFlush(any(ProcessedEvent.class));

    template.process(eventId, logic);

    verify(repository, times(1)).saveAndFlush(any(ProcessedEvent.class));
    verify(logic, never()).run();
  }
}
