package com.example.inventory_service.consumer;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.Exchange;
import org.springframework.amqp.rabbit.annotation.Queue;
import org.springframework.amqp.rabbit.annotation.QueueBinding;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

import java.util.UUID;

@Component
public class DummyOrderCreatedConsumer {

    private static final Logger log = LoggerFactory.getLogger(DummyOrderCreatedConsumer.class);
    private final IdempotentConsumerTemplate idempotentConsumerTemplate;
    private final ObjectMapper objectMapper;

    public DummyOrderCreatedConsumer(IdempotentConsumerTemplate idempotentConsumerTemplate, ObjectMapper objectMapper) {
        this.idempotentConsumerTemplate = idempotentConsumerTemplate;
        this.objectMapper = objectMapper;
    }

    @RabbitListener(bindings = @QueueBinding(
            value = @Queue(value = "inventory.order.created", durable = "true"),
            exchange = @Exchange(value = "chorus.events", type = "topic", durable = "true"),
            key = "order.created"
    ), ackMode = "MANUAL")
    public void onOrderCreated(byte[] messageBytes, com.rabbitmq.client.Channel channel, @org.springframework.messaging.handler.annotation.Header(org.springframework.amqp.support.AmqpHeaders.DELIVERY_TAG) long deliveryTag) {
        String messageJson = new String(messageBytes, java.nio.charset.StandardCharsets.UTF_8);
        try {
            JsonNode root = objectMapper.readTree(messageJson);
            UUID eventId = UUID.fromString(root.get("event_id").asText());
            String correlationId = root.get("correlation_id").asText();

            log.info("Received order.created event [event_id: {}, correlation_id: {}]", eventId, correlationId);

            idempotentConsumerTemplate.process(eventId, () -> {
                // Dummy business logic for Phase 3
                log.info("Processing business logic for order.created (Correlation: {})", correlationId);
            });

            // Manual ACK after successful processing (or duplicate skip)
            channel.basicAck(deliveryTag, false);

        } catch (Exception e) {
            log.error("Failed to process message: {}", messageJson, e);
            try {
                // Nack and requeue on error
                channel.basicNack(deliveryTag, false, true);
            } catch (Exception nackEx) {
                log.error("Failed to nack message", nackEx);
            }
        }
    }
}
