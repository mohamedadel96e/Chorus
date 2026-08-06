package com.example.order_service.consumer;

import com.example.order_service.outbox.ProcessedEvent;
import com.example.order_service.outbox.ProcessedEventRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;

import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

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
                .when(repository).saveAndFlush(any(ProcessedEvent.class));

        template.process(eventId, logic);

        verify(repository, times(1)).saveAndFlush(any(ProcessedEvent.class));
        verify(logic, never()).run();
    }
}
