package com.example.order_service.consumer;

import com.example.order_service.service.OrderService;
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
import org.springframework.amqp.rabbit.annotation.QueueBinding;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.support.AmqpHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Component;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;

@Component
public class OrderEventConsumer {

  private static final Logger log = LoggerFactory.getLogger(OrderEventConsumer.class);
  private final IdempotentConsumerTemplate idempotentConsumerTemplate;
  private final OrderService orderService;
  private final ObjectMapper objectMapper;
  private final Map<UUID, Integer> retryCounts = new ConcurrentHashMap<>();

  public OrderEventConsumer(
      IdempotentConsumerTemplate idempotentConsumerTemplate,
      OrderService orderService,
      ObjectMapper objectMapper) {
    this.idempotentConsumerTemplate = idempotentConsumerTemplate;
    this.orderService = orderService;
    this.objectMapper = objectMapper;
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.shipment.created", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "shipment.created"),
      ackMode = "MANUAL")
  public void onShipmentCreated(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing shipment.created for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "COMPLETED");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.inventory.reservation_failed", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "inventory.reservation_failed"),
      ackMode = "MANUAL")
  public void onReservationFailed(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing inventory.reservation_failed for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.cancelOrder(orderId, "Insufficient stock");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.inventory.released", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "inventory.released"),
      ackMode = "MANUAL")
  public void onInventoryReleased(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing inventory.released for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.cancelOrder(orderId, "Payment or shipment failed - all compensations completed");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.payment.failed", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "payment.failed"),
      ackMode = "MANUAL")
  public void onPaymentFailed(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing payment.failed for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "FAILED_PENDING_COMPENSATION");
        });
  }

  @RabbitListener(
      bindings = 
          @QueueBinding(
              value = @Queue(value = "order.payment.charged", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")), 
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"), 
              key = "payment.charged"), 
      ackMode = "MANUAL")
  public void onPaymentCharged(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing payment.charged for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "CONFIRMED");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.shipment.failed", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "shipment.failed"),
      ackMode = "MANUAL")
  public void onShipmentFailed(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing shipment.failed for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "SHIPMENT_FAILED");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.payment.refunded", durable = "true", arguments = @org.springframework.amqp.rabbit.annotation.Argument(name = "x-dead-letter-exchange", value = "chorus.dlx")),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "payment.refunded"),
      ackMode = "MANUAL")
  public void onPaymentRefunded(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag, @Header(AmqpHeaders.REDELIVERED) boolean redelivered) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        redelivered,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing payment.refunded for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "REFUNDED");
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
