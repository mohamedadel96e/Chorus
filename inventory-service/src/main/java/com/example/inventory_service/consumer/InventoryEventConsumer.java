package com.example.inventory_service.consumer;

import com.example.inventory_service.service.InventoryService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.rabbitmq.client.Channel;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Consumer;
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

@Component
public class InventoryEventConsumer {

  private static final Logger log = LoggerFactory.getLogger(InventoryEventConsumer.class);
  private final IdempotentConsumerTemplate idempotentConsumerTemplate;
  private final InventoryService inventoryService;
  private final ObjectMapper objectMapper;
  private final Map<UUID, Integer> retryCounts = new ConcurrentHashMap<>();

  public InventoryEventConsumer(
      IdempotentConsumerTemplate idempotentConsumerTemplate,
      InventoryService inventoryService,
      ObjectMapper objectMapper) {
    this.idempotentConsumerTemplate = idempotentConsumerTemplate;
    this.inventoryService = inventoryService;
    this.objectMapper = objectMapper;
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
          value = @Queue(value = "inventory.order.created", durable = "true", arguments = @Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
                  exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "order.created"),
      ackMode = "MANUAL")
  public void onOrderCreated(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag,
      @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
            envelope -> {
          JsonNode payload = envelope.get("payload");
          String correlationId = envelope.get("correlation_id").asText();
          log.info("Processing order.created (Correlation: {})", correlationId);
          inventoryService.processOrderCreated(payload, correlationId);
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
          value = @Queue(value = "inventory.payment.failed", durable = "true", arguments = @Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
                  exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "payment.failed"),
      ackMode = "MANUAL")
  public void onPaymentFailed(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag,
      @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
            envelope -> {
          JsonNode payload = envelope.get("payload");
          String correlationId = envelope.get("correlation_id").asText();
          log.info("Processing payment.failed (Correlation: {})", correlationId);
          inventoryService.processPaymentFailedOrRefunded(payload, correlationId);
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
          value = @Queue(value = "inventory.payment.refunded", durable = "true", arguments = @Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
                  exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "payment.refunded"),
      ackMode = "MANUAL")
  public void onPaymentRefunded(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag,
      @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
            envelope -> {
          JsonNode payload = envelope.get("payload");
          String correlationId = envelope.get("correlation_id").asText();
          log.info("Processing payment.refunded (Correlation: {})", correlationId);
          inventoryService.processPaymentFailedOrRefunded(payload, correlationId);
        });
  }

  private void processEvent(
      byte[] messageBytes, Channel channel, long deliveryTag, boolean redelivered, Consumer<JsonNode> logic) {
    String messageJson = new String(messageBytes, StandardCharsets.UTF_8);
    try {
      JsonNode envelope = objectMapper.readTree(messageJson);

      if (envelope.get("event_id") == null || envelope.get("payload") == null) {
        log.warn("Received non-enveloped legacy message, discarding: {}", messageJson);
        channel.basicReject(deliveryTag, false);
        return;
      }

      UUID eventId = UUID.fromString(envelope.get("event_id").asText());

      idempotentConsumerTemplate.process(eventId, () -> logic.accept(envelope));

      retryCounts.remove(eventId);
      channel.basicAck(deliveryTag, false);
    } catch (Exception e) {
      log.error("Failed to process message (Redelivered: {}): {}", redelivered, messageJson, e);
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
            log.warn("Message has failed 3 times, routing to DLQ for event: {}", eventId);
          }
        } else {
          requeue = !redelivered;
          if (!requeue) {
            log.warn("Legacy message failed multiple times, routing to DLQ.");
          }
        }
        channel.basicNack(deliveryTag, false, requeue);
      } catch (Exception nackEx) {
        log.error("Failed to nack message", nackEx);
      }
    }
  }
}
