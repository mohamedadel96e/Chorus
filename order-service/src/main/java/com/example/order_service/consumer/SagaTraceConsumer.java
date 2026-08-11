package com.example.order_service.consumer;

import com.example.order_service.domain.EventTrace;
import com.example.order_service.domain.EventTraceRepository;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.UUID;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.Exchange;
import org.springframework.amqp.rabbit.annotation.Queue;
import org.springframework.amqp.rabbit.annotation.Argument;
import org.springframework.amqp.rabbit.annotation.QueueBinding;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.support.AmqpHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Component;
import com.rabbitmq.client.Channel;

@Component
public class SagaTraceConsumer {

  private static final Logger log = LoggerFactory.getLogger(SagaTraceConsumer.class);
  private final EventTraceRepository eventTraceRepository;
  private final ObjectMapper objectMapper;
  private final Map<UUID, Integer> retryCounts = new ConcurrentHashMap<>();

  public SagaTraceConsumer(
      EventTraceRepository eventTraceRepository, ObjectMapper objectMapper) {
    this.eventTraceRepository = eventTraceRepository;
    this.objectMapper = objectMapper;
  }

  // Bind to the topic exchange with routing key '#' (all events)
  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.saga_trace", durable = "true", arguments = @Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "#"))
  public void onAnyEvent(
      byte[] messageBytes,
      Channel channel,
      @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag,
      @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    String messageJson = new String(messageBytes, StandardCharsets.UTF_8);
    try {
      JsonNode envelope = objectMapper.readTree(messageJson);

      if (envelope.get("event_id") == null
          || envelope.get("correlation_id") == null
          || envelope.get("event_type") == null
          || envelope.get("occurred_at") == null) {
        log.debug("Skipping non-compliant event for trace: {}", messageJson);
        return;
      }

      UUID eventId = UUID.fromString(envelope.get("event_id").asText());
      String correlationId = envelope.get("correlation_id").asText();
      String eventType = envelope.get("event_type").asText();
      
      String occurredAtStr = envelope.get("occurred_at").asText();
      Instant occurredAt;
      try {
        if (occurredAtStr.endsWith("ZZ")) {
            occurredAtStr = occurredAtStr.substring(0, occurredAtStr.length() - 1);
        }
        occurredAt = java.time.format.DateTimeFormatter.ISO_DATE_TIME.parse(occurredAtStr, Instant::from);
      } catch (Exception e) {
        log.warn("Could not parse occurred_at '{}', defaulting to now. Error: {}", occurredAtStr, e.getMessage());
        occurredAt = Instant.now();
      }
      
      JsonNode payloadNode = envelope.get("payload");
      String payload = payloadNode != null ? payloadNode.toString() : "{}";

      // Only save if we haven't seen this exact event (idempotency by event_id)
      boolean exists = false;
      try {
        java.util.List<EventTrace> existing = eventTraceRepository.findByEventId(eventId);
        exists = !existing.isEmpty();
      } catch (Exception ex) {
        log.error("Failed to check event existence for eventId: {}", eventId, ex);
      }

      if (!exists) {
        try {
          EventTrace trace =
              new EventTrace(UUID.randomUUID(), correlationId, eventId, eventType, payload, occurredAt);
          eventTraceRepository.save(trace);
          log.info("Recorded trace for event: {} (Correlation: {})", eventType, correlationId);
        } catch (Exception ex) {
          log.error("Failed to save trace to DB for eventId: {}", eventId, ex);
        }
      }

      retryCounts.remove(eventId);
      channel.basicAck(deliveryTag, false);
    } catch (Exception e) {
      log.error("Failed to process message: {}", messageJson, e);
      try {
        UUID eventId = null;
        try {
          JsonNode envelope = objectMapper.readTree(messageJson);
          if (envelope.get("event_id") != null) {
            eventId = UUID.fromString(envelope.get("event_id").asText());
          }
        } catch (Exception ignore) {}

        boolean requeue = true;
        if (eventId != null) {
          int count = retryCounts.getOrDefault(eventId, 0) + 1;
          retryCounts.put(eventId, count);
          if (count >= 3) {
            requeue = false;
            retryCounts.remove(eventId);
            log.warn("SagaTraceConsumer message failed 3 times, routing to DLQ for event: {}", eventId);
          }
        } else {
          requeue = !redelivered;
        }
        channel.basicNack(deliveryTag, false, requeue);
      } catch (Exception nackEx) {
        log.error("Failed to nack message", nackEx);
      }
    }
  }
}
