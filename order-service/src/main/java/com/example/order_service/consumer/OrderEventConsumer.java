package com.example.order_service.consumer;

import com.example.order_service.service.OrderService;
import com.rabbitmq.client.Channel;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
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
              value = @Queue(value = "order.shipment.created", durable = "true"),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "shipment.created"),
      ackMode = "MANUAL")
  public void onShipmentCreated(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
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
              value = @Queue(value = "order.inventory.reservation_failed", durable = "true"),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "inventory.reservation_failed"),
      ackMode = "MANUAL")
  public void onReservationFailed(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing inventory.reservation_failed for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "CANCELLED");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.inventory.released", durable = "true"),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "inventory.released"),
      ackMode = "MANUAL")
  public void onInventoryReleased(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
        envelope -> {
          JsonNode payload = envelope.get("payload");
          UUID orderId = UUID.fromString(payload.get("order_id").asText());
          log.info(
              "Processing inventory.released for order: {} (Correlation: {})",
              orderId,
              envelope.get("correlation_id").asText());
          orderService.updateOrderStatus(orderId, "CANCELLED");
        });
  }

  @RabbitListener(
      bindings =
          @QueueBinding(
              value = @Queue(value = "order.payment.failed", durable = "true"),
              exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
              key = "payment.failed"),
      ackMode = "MANUAL")
  public void onPaymentFailed(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
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

  @RabbitListener(bindings = @QueueBinding(value = @Queue(value = "order.payment.charged", durable = "true"), exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"), key = "payment.charged"), ackMode = "MANUAL")
  public void onPaymentCharged(
      byte[] messageBytes, Channel channel, @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
    processEvent(
        messageBytes,
        channel,
        deliveryTag,
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

  private void processEvent(
      byte[] messageBytes, Channel channel, long deliveryTag, Consumer<JsonNode> logic) {
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

      channel.basicAck(deliveryTag, false);
    } catch (Exception e) {
      log.error("Failed to process message: {}", messageJson, e);
      try {
        channel.basicNack(deliveryTag, false, true);
      } catch (Exception nackEx) {
        log.error("Failed to nack message", nackEx);
      }
    }
  }
}
