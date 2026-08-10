package com.example.inventory_service.consumer;

import com.example.inventory_service.service.InventoryService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.Exchange;
import org.springframework.amqp.rabbit.annotation.Queue;
import org.springframework.amqp.rabbit.annotation.QueueBinding;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.amqp.support.AmqpHeaders;
import com.rabbitmq.client.Channel;
import java.util.function.Consumer;
import java.util.UUID;
import java.nio.charset.StandardCharsets;

@Component
public class InventoryEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(InventoryEventConsumer.class);
    private final IdempotentConsumerTemplate idempotentConsumerTemplate;
    private final InventoryService inventoryService;
    private final ObjectMapper objectMapper;

    public InventoryEventConsumer(IdempotentConsumerTemplate idempotentConsumerTemplate,
            InventoryService inventoryService,
            ObjectMapper objectMapper) {
        this.idempotentConsumerTemplate = idempotentConsumerTemplate;
        this.inventoryService = inventoryService;
        this.objectMapper = objectMapper;
    }

    @RabbitListener(bindings = @QueueBinding(value = @Queue(value = "inventory.order.created", durable = "true"), exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"), key = "order.created"), ackMode = "MANUAL")
    public void onOrderCreated(byte[] messageBytes, Channel channel,
            @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        processEvent(messageBytes, channel, deliveryTag, envelope -> {
            JsonNode payload = envelope.get("payload");
            String correlationId = envelope.get("correlation_id").asText();
            log.info("Processing order.created (Correlation: {})", correlationId);
            inventoryService.processOrderCreated(payload, correlationId);
        });
    }

    @RabbitListener(bindings = @QueueBinding(value = @Queue(value = "inventory.payment.failed", durable = "true"), exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"), key = "payment.failed"), ackMode = "MANUAL")
    public void onPaymentFailed(byte[] messageBytes, Channel channel,
            @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        processEvent(messageBytes, channel, deliveryTag, envelope -> {
            JsonNode payload = envelope.get("payload");
            String correlationId = envelope.get("correlation_id").asText();
            log.info("Processing payment.failed (Correlation: {})", correlationId);
            inventoryService.processPaymentFailedOrRefunded(payload, correlationId);
        });
    }

    @RabbitListener(bindings = @QueueBinding(value = @Queue(value = "inventory.payment.refunded", durable = "true"), exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"), key = "payment.refunded"), ackMode = "MANUAL")
    public void onPaymentRefunded(byte[] messageBytes, Channel channel,
            @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        processEvent(messageBytes, channel, deliveryTag, envelope -> {
            JsonNode payload = envelope.get("payload");
            String correlationId = envelope.get("correlation_id").asText();
            log.info("Processing payment.refunded (Correlation: {})", correlationId);
            inventoryService.processPaymentFailedOrRefunded(payload, correlationId);
        });
    }

    private void processEvent(byte[] messageBytes, Channel channel, long deliveryTag,
            Consumer<JsonNode> logic) {
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
