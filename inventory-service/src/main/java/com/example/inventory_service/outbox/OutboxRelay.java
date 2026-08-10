package com.example.inventory_service.outbox;

import java.nio.charset.StandardCharsets;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageProperties;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
public class OutboxRelay {

  private static final Logger log = LoggerFactory.getLogger(OutboxRelay.class);
  private final OutboxEventRepository repository;
  private final RabbitTemplate rabbitTemplate;
  private final com.fasterxml.jackson.databind.ObjectMapper objectMapper =
      new com.fasterxml.jackson.databind.ObjectMapper();

  private static final String EXCHANGE_NAME = "chorus.events";

  public OutboxRelay(OutboxEventRepository repository, RabbitTemplate rabbitTemplate) {
    this.repository = repository;
    this.rabbitTemplate = rabbitTemplate;
  }

  @Scheduled(fixedDelayString = "${outbox.relay.delay:5000}")
  @Transactional
  public void relayEvents() {
    List<OutboxEvent> pendingEvents = repository.findByStatusOrderByOccurredAtAsc("PENDING");
    if (pendingEvents.isEmpty()) {
      return;
    }

    log.info("Found {} pending outbox events", pendingEvents.size());

    for (OutboxEvent event : pendingEvents) {
      try {
        MessageProperties props = new MessageProperties();
        props.setContentType(MessageProperties.CONTENT_TYPE_JSON);
        props.setMessageId(event.getId().toString());
        props.setCorrelationId(event.getCorrelationId().toString());
        props.setTimestamp(java.util.Date.from(event.getOccurredAt()));

        com.fasterxml.jackson.databind.node.ObjectNode envelope = objectMapper.createObjectNode();
        envelope.put("event_id", event.getId().toString());
        envelope.put("event_type", event.getEventType());
        envelope.put("event_version", 1);
        envelope.put("correlation_id", event.getCorrelationId().toString());
        envelope.put("occurred_at", event.getOccurredAt().toString() + "Z");

        com.fasterxml.jackson.databind.JsonNode payloadNode =
            objectMapper.readTree(event.getPayload());
        envelope.set("payload", payloadNode);

        String envelopeJson = objectMapper.writeValueAsString(envelope);

        Message message = new Message(envelopeJson.getBytes(StandardCharsets.UTF_8), props);

        rabbitTemplate.send(EXCHANGE_NAME, event.getRoutingKey(), message);

        event.setStatus("PUBLISHED");
        repository.save(event);

        log.info(
            "Successfully published event {} with routing key {}",
            event.getId(),
            event.getRoutingKey());
      } catch (Exception e) {
        log.error("Failed to publish event {}", event.getId(), e);
      }
    }
  }
}
