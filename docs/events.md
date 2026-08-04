# Chorus Event Catalog

This document is the **single source of truth** for every domain event in the Chorus system. I designed these contracts before writing a single line of service logic - in choreography, the event shape _is_ the API, and getting it right here saves me from painful cross-service refactors later. Every service in every language (Java, TypeScript, PHP) must be able to produce and consume these events using nothing but a JSON serializer and a RabbitMQ client.

---

## Conventions

### Base Event Envelope

Every event published to RabbitMQ conforms to this envelope. I chose this shape so that any consumer - regardless of language - can deserialize the metadata fields without knowing the business payload in advance. A Java consumer can parse `event_type` and `correlation_id` before it even looks at `payload`, and a TypeScript consumer can do the same with zero shared libraries.

```json
{
  "event_id": "string (UUID v4)",
  "event_type": "string (PascalCase, e.g. OrderCreated)",
  "event_version": 1,
  "correlation_id": "string (UUID v4 - the original order_id, carried through every hop)",
  "occurred_at": "string (ISO 8601, e.g. 2026-07-31T17:00:00Z)",
  "payload": {}
}
```

| Field | Type | Purpose |
|---|---|---|
| `event_id` | UUID v4 | Globally unique per event instance. Used for idempotency checks in `processed_events` tables. Every consumer checks this ID before processing - if it has seen this `event_id` before, it skips the event entirely. This is how I get exactly-once semantics on top of RabbitMQ's at-least-once delivery. |
| `event_type` | string | Machine-readable discriminator. Consumers use this to route to the correct handler function. I chose PascalCase (`OrderCreated`, not `order_created` or `order-created`) because it matches the natural class naming in both Java and TypeScript, making deserialization mapping trivial. |
| `event_version` | integer | Starts at `1`. Bumped when I make breaking changes to the payload shape. Consumers must check this field and handle unknown versions gracefully - either process the known fields and ignore new ones, or reject the message to a dead-letter queue for manual inspection. I am not using a schema registry yet; the version integer plus tolerant reader pattern is sufficient for four services. |
| `correlation_id` | UUID v4 | Set once by the Order service when it creates the order. Every downstream event for the same order carries this same ID, unchanged. This is how the Saga Trace Dashboard reconstructs a full timeline from `OrderCreated` through to `OrderCompleted` or `OrderCancelled`. Without this field, I would need to join across four separate databases to answer "what happened to order X?" |
| `occurred_at` | ISO 8601 string | Timestamp of when the event was created. I chose ISO 8601 over Unix epoch because it is human-readable in logs and broker management UIs, which matters when I am debugging a stuck saga at 2 AM. `"2026-07-31T17:00:02Z"` is immediately interpretable; `1785354002` is not. I always emit in UTC (the `Z` suffix) to avoid timezone ambiguity across services that might run in different containers with different locale settings. |
| `payload` | object | Business-specific data. Varies per event type. Documented exhaustively below. Every consumer must be written to **tolerate unknown fields** in this object from day one - I will add fields, and consumers that blow up on unexpected keys are a deployment hazard. |

### Money Representation

All monetary values are represented as **integers in the smallest currency unit** (e.g. cents for USD). I chose this over decimals because floating-point arithmetic behaves differently across Java, TypeScript, and PHP - and in a polyglot system, a 0.01 rounding discrepancy between Payment (NestJS) and Order (Spring Boot) would be a silent, devastating bug.

Example: `$15.99` -> `1599` (with `currency: "USD"`)

Every event that carries a monetary value also carries a `currency` field. I never assume USD - even though it is the only currency I support today, baking that assumption into the payload shape would mean a schema migration when I add multi-currency support. The `currency` field costs me 14 bytes per event and saves me a breaking change later.

### RabbitMQ Routing

#### Why a Topic Exchange

I use a single **topic exchange** named `chorus.events`. I considered three exchange types before settling on this:

1. **Direct exchange** - Each routing key maps to exactly one queue. This would work, but it means if a new service wants to listen to `order.created`, I have to create a new binding with the exact routing key. Direct exchanges have no wildcard support, so the Saga Trace Dashboard would need one binding per event type - 11 bindings today, growing with every new event. Manageable, but brittle.

2. **Fanout exchange** - Every bound queue receives every message. This is too coarse. My Inventory service does not care about `shipment.created`, but with a fanout exchange it would receive it anyway. I would have to filter in application code, which wastes bandwidth, CPU, and makes it harder to reason about message flow. In a system where I am deliberately practicing observability, I want the broker to do the routing, not my application code.

3. **Topic exchange** (my choice) - Routing keys are dot-delimited strings, and consumers bind with patterns that can include wildcards (`*` matches one word, `#` matches zero or more words). This gives me the best of both worlds: selective routing without needing a separate exchange per event type. The Saga Trace Dashboard binds to `#` (all events) with a single binding. The Inventory service binds to `order.created`, `payment.failed`, and `payment.refunded` - exactly the three events it cares about. If I later add a `notification-service` that cares about all order events, it binds to `order.*` and gets `order.created`, `order.completed`, and `order.cancelled` without any changes to publishers or existing consumers.

The slight performance overhead of topic exchange routing (the broker must pattern-match routing keys against bindings) is negligible at my scale - it matters at millions of messages per second, not hundreds.

#### Routing Key Naming Convention

Each event is published with a routing key following the pattern:

```
<service>.<action>
```

I considered two alternatives before choosing this:

- **`<domain>.<event_type>`** (e.g. `order.order_created`, `inventory.inventory_reserved`) - Redundant. The service name is already embedded in the event type. Writing `inventory.inventory_reserved` stutters and adds no information.

- **Reverse DNS style** (e.g. `com.chorus.order.created`) - Too verbose. RabbitMQ routing keys are not Java packages. The extra segments add nothing useful for pattern matching and make the management UI harder to scan. I want routing keys that fit on one line of a log.

My convention - `order.created`, `inventory.reserved`, `payment.charged` - is terse, scannable, and groups naturally. All events from the same service share a prefix, so `order.*` catches everything the Order service emits. The action part is a past-tense verb describing what happened, not what should happen - this reinforces that events are facts, not commands.

| Routing Key | Event Type |
|---|---|
| `order.created` | `OrderCreated` |
| `inventory.reserved` | `InventoryReserved` |
| `inventory.reservation_failed` | `InventoryReservationFailed` |
| `inventory.released` | `InventoryReleased` |
| `payment.charged` | `PaymentCharged` |
| `payment.failed` | `PaymentFailed` |
| `payment.refunded` | `PaymentRefunded` |
| `shipment.created` | `ShipmentCreated` |
| `shipment.failed` | `ShipmentFailed` |
| `order.completed` | `OrderCompleted` |
| `order.cancelled` | `OrderCancelled` |

#### Queue Naming and Binding Strategy

Each service gets one **durable queue** per routing key it cares about. The queue name follows the convention:

```
<service>.<routing_key>
```

For example, when the Inventory service binds to `order.created`, the queue is named `inventory.order.created`. When the Order service binds to `inventory.released`, the queue is named `order.inventory.released`.

I chose this naming convention for three reasons:

1. **Uniqueness without coordination.** Two services can both consume the same event (e.g. both Inventory and Order consume `payment.failed`) without conflicting queue names. Inventory gets `inventory.payment.failed`, Order gets `order.payment.failed`. Each queue is independent - they each get their own copy of the message.

2. **Debuggability.** When I open the RabbitMQ management UI, I can immediately see which service owns which queue. If `inventory.order.created` has 5,000 unacked messages, I know the Inventory service is struggling with order creation events. I do not need to cross-reference a spreadsheet.

3. **One queue per binding.** I do not multiplex multiple routing keys onto a single queue per service. I could - RabbitMQ allows it - but separate queues give me independent backpressure, independent dead-letter routing, and independent monitoring. If payment failure processing is slow, I do not want it blocking shipment failure processing on the same queue.

The Saga Trace Dashboard is the exception - it uses a single queue `trace.all` bound to `#` because it needs every event in arrival order.

#### Message Persistence

Every message is published with **persistent delivery mode** (`delivery_mode: 2` in AMQP terms). Combined with durable queues and a durable exchange, this means messages survive a RabbitMQ broker restart. I cannot afford to lose an `InventoryReserved` event because the broker rebooted between publish and consume - that would leave stock permanently reserved with no payment ever attempted.

The cost of persistence is that RabbitMQ must `fsync` each message to disk before acknowledging the publish. This adds a few milliseconds of latency per message. At my scale (tens of orders per second, not thousands), this is an easy tradeoff. If I needed higher throughput, I would look at publisher confirms with batching, but for now simple persistent mode is correct and simple.

#### Consumer Acknowledgment Strategy

All consumers use **manual acknowledgment** - not auto-ack. The processing flow for every consumer is:

1. Receive the message from RabbitMQ (message is now "unacked" on the broker - the broker holds it in case this consumer dies).
2. Check the `event_id` against the `processed_events` table. If already seen, ack and skip.
3. Inside a single database transaction: perform the business logic, insert a row into `processed_events`, and insert the outgoing event into the `outbox_events` table.
4. Only after the transaction commits: send the manual ack to RabbitMQ.

If the consumer crashes between step 1 and step 4, RabbitMQ will redeliver the message to another consumer instance (or the same one after it restarts). The idempotency check in step 2 ensures the redelivered message is not processed twice.

I explicitly chose not to use auto-ack because auto-ack tells RabbitMQ "this message is consumed" the instant it is delivered to my application - before I have done anything with it. If my application crashes after receiving but before processing, the message is gone forever. In a saga where lost events mean stuck orders, that is unacceptable.

![Acknowledgement](./Assets/Acknoledgement.svg)

---

## Happy Path Events

### 1. `OrderCreated`

**Producer:** Order Service
**Routing Key:** `order.created`
**Consumers:** Inventory Service
**Trigger:** A customer submits `POST /orders`.

```json
{
  "event_id": "a1b2c3d4-0001-4000-8000-000000000001",
  "event_type": "OrderCreated",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:00Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "customer_id": "cust-9281",
    "items": [
      {
        "product_id": "prod-001",
        "quantity": 2,
        "unit_price_cents": 1500
      },
      {
        "product_id": "prod-007",
        "quantity": 1,
        "unit_price_cents": 3200
      }
    ],
    "total_amount_cents": 6200,
    "currency": "USD"
  }
}
```

#### What happens in the service

When the Order service receives `POST /orders`, the following business logic runs before this event is emitted:

1. **Input validation.** The service validates the request body: `customer_id` must be non-empty, `items` must be a non-empty array, each item must have a positive `quantity` and a non-negative `unit_price_cents`. The `total_amount_cents` is recalculated server-side (never trusted from the client) by summing `quantity * unit_price_cents` across all items.

2. **Order creation.** A new order record is inserted into the `orders` table in `order_db` with status `pending`. The `order_id` is a freshly generated UUID v4 - this same value becomes the `correlation_id` for the entire saga.

3. **Outbox insert.** Within the same database transaction that creates the order, a row is inserted into `outbox_events` containing the serialized `OrderCreated` event. This is the transactional outbox pattern - I never publish directly to RabbitMQ from within the request handler, because if the publish succeeds but the database commit fails (or vice versa), the system ends up in an inconsistent state.

4. **Response.** The API returns `201 Created` with the order ID. The event has not been published yet - it is sitting in the outbox. The OutboxRelay background worker picks it up and publishes it to RabbitMQ.

#### What consumers should do

**Inventory Service** (queue: `inventory.order.created`):
- Parse the `items` array from the payload.
- For each item, attempt to decrement available stock by the requested `quantity` using an atomic database operation (e.g. `UPDATE products SET available_stock = available_stock - :qty WHERE product_id = :id AND available_stock >= :qty`).
- If all items are successfully reserved: create a reservation record, insert `InventoryReserved` into the outbox, ack the message.
- If any item fails: do not reserve any items (all-or-nothing), insert `InventoryReservationFailed` into the outbox with per-item detail, ack the message.

#### Edge cases and validation

- **Duplicate `OrderCreated` events.** RabbitMQ's at-least-once delivery means the Inventory service might receive this event twice. The `processed_events` table check on `event_id` prevents double-reservation. Without this, a customer could end up with twice the reserved stock.
- **Empty items array.** Should never happen if the Order service validates correctly, but the Inventory service should treat an empty `items` array as a no-op and emit `InventoryReserved` with an empty items list. Defensive coding - I do not want a downstream service to crash because an upstream service had a validation bug.
- **Unknown `product_id`.** If the Inventory service receives a `product_id` it does not recognize, it should treat that item as having zero available stock and include it in the `InventoryReservationFailed` response.
- **Order service restart between commit and outbox relay.** If the Order service crashes after committing the order but before the OutboxRelay publishes the event, the event is still in the outbox table. When the relay restarts, it picks up unpublished events and publishes them. The order is not lost.

#### Design notes

- **`correlation_id` equals `order_id`.** This is the originating event, so the `correlation_id` is set to the `order_id` itself. Every subsequent event in this saga carries the same `correlation_id`. I chose not to generate a separate saga ID because the order ID is already unique and meaningful - adding a second UUID would be pure overhead with no benefit.
- **`total_amount_cents` is denormalized.** I include both the item-level prices and the pre-computed total. This is intentional redundancy: the Payment service needs the total to charge, but the Inventory service does not care about prices at all. Including both saves the Payment service from having to recompute the total from the items array, which would mean duplicating arithmetic logic across languages.
- **`unit_price_cents` in the event, not looked up by the consumer.** The price is a snapshot at order time. If product prices change between order creation and inventory reservation, the Inventory service should still use the price from the event. This is the "fat event" philosophy - the event carries a point-in-time snapshot of everything the downstream services need.

---

### 2. `InventoryReserved`

**Producer:** Inventory Service
**Routing Key:** `inventory.reserved`
**Consumers:** Payment Service
**Trigger:** Inventory service successfully reserves stock for all items in the order.

```json
{
  "event_id": "a1b2c3d4-0002-4000-8000-000000000002",
  "event_type": "InventoryReserved",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:01Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "reservation_id": "res-55012",
    "items": [
      {
        "product_id": "prod-001",
        "quantity": 2
      },
      {
        "product_id": "prod-007",
        "quantity": 1
      }
    ]
  }
}
```

#### What happens in the service

When the Inventory service consumes an `OrderCreated` event and all items can be reserved, the following logic runs:

1. **Atomic stock decrement.** For each item in the order, the service decrements `available_stock` in the products table using a conditional update (`WHERE available_stock >= :requested_quantity`). This is done inside a single database transaction to ensure all-or-nothing semantics - if item 2 of 3 fails, the decrements for items 1 are rolled back.

2. **Reservation record.** A new reservation record is created with a unique `reservation_id`, linking the `order_id` to the reserved items and quantities. This record serves two purposes: it is the audit trail for what was reserved, and it is the lookup key for the compensation event (`InventoryReleased`) to know exactly what to undo.

3. **Outbox insert.** The `InventoryReserved` event is written to the outbox within the same transaction that decremented stock and created the reservation. This ensures I cannot decrement stock without eventually emitting the event, and I cannot emit the event without having decremented stock.

#### What consumers should do

**Payment Service** (queue: `payment.inventory.reserved`):
- Extract `order_id` from the payload.
- Look up the order's payment details. In my design, the Payment service does not need item-level detail for charging - it needs the `total_amount_cents` and `currency`. These are not in this event (they were in `OrderCreated`). The Payment service must have stored the order amount when... actually, the Payment service never saw `OrderCreated`. This is a key design decision: the Payment service receives the amount through a different mechanism. In my current design, I carry `total_amount_cents` and `currency` forward by having the Payment service look them up from the `InventoryReserved` event's context - but those fields are not in this payload. **This means I need the Payment service to have access to the order amount.** I handle this by having the Payment service store necessary order details from the `OrderCreated` event context. In practice, the Payment service binds only to `inventory.reserved`, so I need to ensure the amount flows through. I solve this by including the order amount in the `InventoryReserved` payload in my actual implementation, or by having the Payment service query a read model. For this initial design, I lean on the fat-event principle: the Inventory service forwards the financial data it received.
- Initiate the payment charge for the full order amount.
- On success: insert `PaymentCharged` into the outbox.
- On failure: insert `PaymentFailed` into the outbox.

#### Edge cases and validation

- **Partial reservation is not allowed.** If the order has 3 items and only 2 can be reserved, the service does not reserve the 2 and fail the 1. It fails the entire reservation and emits `InventoryReservationFailed`. I made this choice because partial fulfillment dramatically complicates the compensation chain - the Payment service would need to know which items to charge for, and the customer would get a surprise partial order.
- **Concurrent reservations for the same product.** Two orders arriving simultaneously for the last unit of `prod-007` will race on the `WHERE available_stock >= :qty` check. Only one will succeed - the database's row-level lock ensures this. The other gets `InventoryReservationFailed`. This is correct behavior, not a bug.
- **Reservation expiry.** In this initial design, reservations do not expire. In a production system, I would add a TTL and a background job that releases stale reservations (e.g. if the Payment service never responds within 15 minutes). For now, the compensation events handle all release scenarios.

#### Design notes

- **`reservation_id` is critical.** I include the `reservation_id` so that the compensation event (`InventoryReleased`) can reference exactly which reservation to undo. Without this, I would need to look up the reservation by `order_id`, which adds an unnecessary query and a potential race condition if the same order somehow generated multiple reservations (a bug, but one I want to handle gracefully).
- **No price data in this event.** The Inventory service does not own pricing - it only knows about stock quantities. Including `unit_price_cents` here would mean the Inventory service is responsible for forwarding data it does not own, which violates the bounded context. The Payment service gets its pricing information through the saga's data flow, not from the Inventory service.
- **Items array mirrors the request.** The `items` array in this event matches what was requested in `OrderCreated`. I include it so that the full reservation detail is visible in the Saga Trace Dashboard without needing to correlate back to the original `OrderCreated` event.

---

### 3. `PaymentCharged`

**Producer:** Payment Service
**Routing Key:** `payment.charged`
**Consumers:** Shipping Service
**Trigger:** Payment service successfully charges the customer.

```json
{
  "event_id": "a1b2c3d4-0003-4000-8000-000000000003",
  "event_type": "PaymentCharged",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:02Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "payment_id": "pay-78301",
    "amount_cents": 6200,
    "currency": "USD"
  }
}
```

#### What happens in the service

When the Payment service consumes an `InventoryReserved` event, the following logic runs before this event is emitted:

1. **Payment record creation.** A new payment record is created in `payment_db` with status `pending`, linking the `order_id` to the `amount_cents` and `currency`.

2. **Charge execution.** The service calls the payment provider (in my case, a simulated charge - in production this would be Stripe, Braintree, etc.). The charge is executed for the full `amount_cents`.

3. **Status update.** On successful charge, the payment record is updated to status `charged`. The `payment_id` is the unique identifier for this payment record - it is what the `PaymentRefunded` compensation event will reference later.

4. **Outbox insert.** The `PaymentCharged` event is inserted into the outbox within the same transaction that updated the payment status to `charged`.

The key subtlety here is that the external payment provider call happens _outside_ the database transaction. I cannot wrap a Stripe API call in a Postgres transaction. So the flow is: begin transaction -> create pending payment -> commit -> call Stripe -> begin transaction -> update to charged + insert outbox -> commit. If the service crashes between the Stripe charge and the second commit, I have charged the customer but not emitted the event. The OutboxRelay will not find an event to publish. This is a known gap that I address with a reconciliation job in production - but for this learning project, I note the tradeoff and move on.

#### What consumers should do

**Shipping Service** (queue: `shipping.payment.charged`):
- Extract `order_id` from the payload.
- Look up or derive the shipping address and items for the order (the Shipping service needs to know what to ship and where - this data flows through the saga or is stored in a read model).
- Attempt to create a shipment record, which might involve calling a carrier API for label generation and tracking number creation.
- On success: insert `ShipmentCreated` into the outbox with the tracking number and estimated delivery date.
- On failure: insert `ShipmentFailed` into the outbox with the reason.

#### Edge cases and validation

- **Payment provider timeout.** If the payment provider does not respond within the timeout window, the Payment service should treat this as a failure and emit `PaymentFailed`. I do not retry at the payment level because I do not know if the charge went through - retrying could double-charge the customer. Instead, I fail fast and let the compensation chain handle it. A reconciliation job can check for orphaned charges later.
- **Amount mismatch.** The Payment service should validate that the `amount_cents` it is about to charge matches the amount it expected from the order context. If there is a mismatch (which would indicate a bug, not a user error), it should log the discrepancy and emit `PaymentFailed` rather than charging the wrong amount.
- **Idempotent charges.** If the same `InventoryReserved` event is delivered twice, the idempotency check on `event_id` prevents a double charge. This is critical - double-charging a customer is one of the worst failure modes in an e-commerce system.

#### Design notes

- **`payment_id` serves the same purpose as `reservation_id`.** It is the unique identifier that the compensation event (`PaymentRefunded`) will reference. Without it, the refund logic would need to look up payments by `order_id`, introducing an extra query and a potential ambiguity if multiple payment attempts exist for the same order.
- **No item-level detail.** The Payment service charges at the order level, not the item level. Including items here would be noise - the Shipping service needs items for packing, but it should get them from its own data store or the order context, not from a payment event.
- **Forward compatibility.** In the future, I will bump this to v2 and add a `payment_method` field (e.g. `"credit_card"`, `"paypal"`). The Shipping service consumer must be written to tolerate unknown fields from day one - it should not break when it sees a field it does not recognize.

---

### 4. `ShipmentCreated`

**Producer:** Shipping Service
**Routing Key:** `shipment.created`
**Consumers:** Order Service
**Trigger:** Shipping service successfully creates a shipment record.

```json
{
  "event_id": "a1b2c3d4-0004-4000-8000-000000000004",
  "event_type": "ShipmentCreated",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:03Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "shipment_id": "ship-44109",
    "tracking_number": "TRK-2026-ABCDEF",
    "estimated_delivery": "2026-08-05"
  }
}
```

#### What happens in the service

When the Shipping service consumes a `PaymentCharged` event, the following logic runs:

1. **Shipment record creation.** A new shipment record is created in `shipping_db` with the `order_id`, a generated `shipment_id`, and status `created`.

2. **Carrier integration.** The service calls the shipping carrier's API (simulated in this project) to generate a tracking number and get an estimated delivery date. In a real system, this would involve address validation, rate calculation, and label generation.

3. **Record update.** The shipment record is updated with the tracking number and estimated delivery date.

4. **Outbox insert.** The `ShipmentCreated` event is inserted into the outbox within the same transaction that finalized the shipment record.

This is the last step in the happy path. Once the Order service receives this event, the saga is complete.

#### What consumers should do

**Order Service** (queue: `order.shipment.created`):
- Update the order status from `pending` to `completed` in `order_db`.
- Store the `tracking_number` and `estimated_delivery` on the order record (or in a related shipment details table) so the customer can query their order status via the API.
- Insert `OrderCompleted` into the outbox. This is a terminal event - it signals that the saga has reached its successful conclusion.
- Ack the message.

#### Edge cases and validation

- **Carrier API failure vs. shipment failure.** If the carrier API is down (network error, timeout), the Shipping service should retry a few times before giving up. If it gives up, it emits `ShipmentFailed`. I distinguish between a temporary carrier outage (retry) and a permanent rejection (e.g. invalid address) - only permanent rejections get `ShipmentFailed` immediately.
- **Order already cancelled.** If the Order service receives `ShipmentCreated` but the order is already in `cancelled` status (which would be a bug in the saga flow), it should log a warning, ack the message, and not emit `OrderCompleted`. Transitioning from `cancelled` to `completed` would be a state machine violation.
- **Duplicate `ShipmentCreated`.** The idempotency check on `event_id` prevents the Order service from completing the same order twice. The second delivery is a no-op.

#### Design notes

- **`estimated_delivery` is a date, not a datetime.** I use `YYYY-MM-DD` format because delivery estimates are inherently imprecise - saying "arrives by 2026-08-05T14:30:00Z" implies false precision. A date is honest.
- **`tracking_number` is a string, not a structured object.** Different carriers have different tracking number formats. I do not try to normalize them - the tracking number is an opaque string that gets passed to the customer.
- **This event completes the happy path.** The `ShipmentCreated` -> `OrderCompleted` transition is the only path to a successful saga conclusion. There is no shortcut, no way to skip shipping. This is by design - in a real e-commerce system, you do not want orders marked as "completed" before a shipment exists.

---

## Failure Events

### 5. `InventoryReservationFailed`

**Producer:** Inventory Service
**Routing Key:** `inventory.reservation_failed`
**Consumers:** Order Service
**Trigger:** One or more items in the order do not have sufficient stock.

```json
{
  "event_id": "a1b2c3d4-0005-4000-8000-000000000005",
  "event_type": "InventoryReservationFailed",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:01Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "reason": "Insufficient stock for one or more items",
    "items": [
      {
        "product_id": "prod-007",
        "requested_quantity": 1,
        "available_quantity": 0
      }
    ]
  }
}
```

#### What happens in the service

When the Inventory service consumes an `OrderCreated` event and cannot reserve all items, the following logic runs:

1. **Stock check.** The service checks available stock for each item in the order. It does this within a transaction to get a consistent snapshot.

2. **Failure detection.** If any item has `available_stock < requested_quantity`, the entire reservation fails. No partial reservations are created. The service collects the list of items that could not be fulfilled, including their `requested_quantity` and `available_quantity`.

3. **No stock mutation.** Unlike the success path, no stock is decremented. The database state is unchanged. This is important - since nothing was reserved, there is nothing to compensate later. This is why this is the simplest failure path in the entire saga.

4. **Outbox insert.** The `InventoryReservationFailed` event is inserted into the outbox. Since no stock was mutated, this outbox insert can technically happen outside a critical transaction - but I keep it transactional with the `processed_events` insert for consistency.

#### What consumers should do

**Order Service** (queue: `order.inventory.reservation_failed`):
- Update the order status from `pending` to `cancelled` in `order_db`.
- Store the `reason` and the per-item failure details on the order record (or in a related cancellation reasons table) so the customer can be told exactly why their order failed.
- Insert `OrderCancelled` into the outbox with a reason indicating inventory failure.
- Ack the message.

This is the simplest compensation chain - no prior steps need undoing. The order was `pending`, nothing was reserved, nothing was charged, nothing was shipped. The order just moves to `cancelled`.

#### Edge cases and validation

- **All items out of stock vs. some items.** The `items` array in this event only includes items that failed - not items that could have been fulfilled. This is a deliberate choice: the consumer needs to know what went wrong, not what went right. If the customer had 5 items in their order and 1 was out of stock, only that 1 item appears in this event's `items` array.
- **Stock became available between check and event processing.** By the time the Order service processes this failure event, the stock might have been replenished. That is fine - the Order service does not retry the reservation. The customer needs to place a new order. Retrying automatically would create ordering fairness issues and potentially infinite retry loops.
- **Concurrent orders exhausting stock.** If two orders arrive for the last unit simultaneously, one gets `InventoryReserved` and the other gets `InventoryReservationFailed`. The database's row-level locking ensures there is no overselling.

#### Design notes

- **Per-item detail in the failure event.** I include `requested_quantity` and `available_quantity` for each failing item. This lets the Order service (or a future UI) tell the customer exactly which item is out of stock and how many are available - not just "order failed." It costs me a few extra bytes per event but saves a support ticket.
- **`reason` is a human-readable string, not an error code.** I chose human-readable reasons because this is a learning project where debuggability matters more than machine parsing. In a production system with many failure reasons, I would add a `reason_code` enum alongside the human-readable string.
- **No `reservation_id` in this event.** Since no reservation was created, there is no reservation to reference. This asymmetry between the success event (has `reservation_id`) and the failure event (does not) is intentional - it reflects the reality that different outcomes produce different data.

---

### 6. `PaymentFailed`

**Producer:** Payment Service
**Routing Key:** `payment.failed`
**Consumers:** Inventory Service, Order Service
**Trigger:** Payment charge is declined or errors out.

```json
{
  "event_id": "a1b2c3d4-0006-4000-8000-000000000006",
  "event_type": "PaymentFailed",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:02Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "payment_id": "pay-78301",
    "amount_cents": 6200,
    "currency": "USD",
    "reason": "Card declined by issuing bank"
  }
}
```

#### What happens in the service

When the Payment service consumes an `InventoryReserved` event and the charge fails, the following logic runs:

1. **Payment record creation.** A payment record is created with status `pending`.

2. **Charge attempt.** The service calls the payment provider. The charge is declined (e.g. insufficient funds, expired card, fraud detection).

3. **Status update.** The payment record is updated to status `failed` with the reason from the provider.

4. **Outbox insert.** The `PaymentFailed` event is inserted into the outbox within the same transaction that updated the payment status. The `payment_id` is included even though the payment failed - it is the reference ID for this failed attempt, useful for auditing and customer support.

This event has **two consumers**, which is the first event in the saga where a single event triggers reactions in multiple services. RabbitMQ's topic exchange handles this naturally - each consumer has its own queue, and each queue gets its own copy of the message.

#### What consumers should do

**Inventory Service** (queue: `inventory.payment.failed`):
- Look up the reservation for this `order_id`. The Inventory service needs to find the `reservation_id` that was created when it processed the original `OrderCreated` event.
- Release the reserved stock by incrementing `available_stock` for each reserved item.
- Mark the reservation record as `released` (do not delete it - it stays for audit).
- Insert `InventoryReleased` into the outbox with the `reservation_id` and items that were released.
- Ack the message.

**Order Service** (queue: `order.payment.failed`):
- The Order service does **not** immediately cancel the order when it receives `PaymentFailed`. Instead, it waits for `InventoryReleased` to arrive - that is the signal that the full compensation chain is complete.
- Why? Because if the Order service cancelled immediately on `PaymentFailed`, it would be racing the Inventory service's compensation. The order would be marked `cancelled` before the stock is actually released, which creates a window where the system state is inconsistent (order cancelled, but stock still reserved).
- In practice, the Order service can update the order with an intermediate status like `payment_failed` for visibility, but the terminal `cancelled` status and the `OrderCancelled` event are only emitted after `InventoryReleased` arrives.

#### Edge cases and validation

- **Inventory service receives `PaymentFailed` before it has finished processing `OrderCreated`.** This is a race condition. If events arrive out of order, the Inventory service might receive `PaymentFailed` for an order it has not yet reserved. The service should check if a reservation exists - if not, it can either buffer the event for retry or simply ack it (since there is nothing to release). I handle this in the future.
- **Multiple payment attempts.** In this design, there is only one payment attempt per saga. If the payment fails, the saga compensates and cancels. I do not retry the payment with a different card - that would require user interaction and a different saga flow entirely.
- **Reason field sensitivity.** The `reason` string comes from the payment provider and might contain sensitive information. I should be careful about what I log and expose to the customer. "Card declined by issuing bank" is fine; "Fraud suspected, account flagged" might need to be sanitized.

#### Design notes

- **Two consumers, not one.** This is the first event with multiple consumers. I considered having only the Inventory service consume this (and then the Order service reacts to `InventoryReleased`), but I also route it to the Order service so it can show the payment failure reason to the customer immediately, without waiting for the full compensation chain. The Order service does not act on it terminally - it just records the reason.
- **`amount_cents` and `currency` are included even though the charge failed.** This is for the Saga Trace Dashboard - when reconstructing the saga timeline, seeing the attempted amount in the failure event is more useful than having to cross-reference the original `OrderCreated` event.
- **`payment_id` references a failed payment.** Unlike `reservation_id` in `InventoryReservationFailed` (which is absent because no reservation was created), the `payment_id` exists because a payment record was created - it just has status `failed`. The record is useful for audit and reconciliation.

---

### 7. `ShipmentFailed`

**Producer:** Shipping Service
**Routing Key:** `shipment.failed`
**Consumers:** Payment Service, Order Service
**Trigger:** Shipment could not be created (e.g. address validation failure, carrier API down).

```json
{
  "event_id": "a1b2c3d4-0007-4000-8000-000000000007",
  "event_type": "ShipmentFailed",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:03Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "shipment_id": "ship-44109",
    "reason": "Shipping address validation failed"
  }
}
```

#### What happens in the service

When the Shipping service consumes a `PaymentCharged` event and cannot create a shipment, the following logic runs:

1. **Shipment attempt.** The service attempts to create a shipment - this might involve address validation, carrier API calls for rate quotes, or label generation.

2. **Failure handling.** The carrier API returns an error, or the address validation fails, or some other condition prevents shipment creation. The service records the failure reason.

3. **Shipment record update.** If a shipment record was created (with a `shipment_id`), it is updated to status `failed`. If the failure happened before a record could be created, a new record is created with status `failed` and a generated `shipment_id`.

4. **Outbox insert.** The `ShipmentFailed` event is inserted into the outbox. This triggers the longest compensation chain in the system.

#### What consumers should do

**Payment Service** (queue: `payment.shipment.failed`):
- Look up the payment record for this `order_id`.
- Initiate a refund for the full charged amount. In a real system, this means calling the payment provider's refund API (e.g. `stripe.refunds.create()`).
- Update the payment record to status `refunded`.
- Insert `PaymentRefunded` into the outbox with the `refund_id`, `payment_id`, amount, and reason.
- Ack the message.

**Order Service** (queue: `order.shipment.failed`):
- Similar to `PaymentFailed`, the Order service does **not** immediately cancel the order. It records the shipment failure reason and waits for the full compensation chain to complete (`PaymentRefunded` -> `InventoryReleased` -> then `OrderCancelled`).
- The Order service can set an intermediate status like `shipment_failed` for customer visibility.

#### Edge cases and validation

- **Refund failure.** What if the Payment service cannot process the refund? The payment provider might be down, or the refund might be rejected. In this case, the Payment service should not emit `PaymentRefunded` - it should retry the refund (with exponential backoff) or move the message to a dead-letter queue for manual intervention. A stuck refund is a serious business problem - the customer has been charged but has no product.
- **Payment already refunded.** If the Payment service receives `ShipmentFailed` but the payment is already in `refunded` status (perhaps from a manual intervention), it should ack the message and not attempt a double refund. The idempotency check on `event_id` handles duplicate deliveries, but this check handles the business-level idempotency of "has a refund already been issued for this order?"
- **Order service receives `ShipmentFailed` but order is already cancelled.** If somehow the order is already cancelled (e.g. from a concurrent failure path), the Order service should ack and ignore. No state transition needed.

#### Design notes

- **Longest compensation chain.** This event triggers the most complex compensation in the system: `ShipmentFailed` -> `PaymentRefunded` -> `InventoryReleased` -> `OrderCancelled`. Three services must unwind their work in reverse order.
- **`shipment_id` is included even on failure.** Same rationale as `payment_id` in `PaymentFailed` - a record was created, it just has a `failed` status. The ID is useful for debugging and audit.
- **`reason` covers diverse failure modes.** Address validation failures, carrier API timeouts, and carrier rejections all produce `ShipmentFailed` with different `reason` strings. I do not distinguish between them at the event level because the compensation flow is identical regardless of why the shipment failed.

---

## Compensation Events

### 8. `InventoryReleased`

**Producer:** Inventory Service
**Routing Key:** `inventory.released`
**Consumers:** Order Service
**Trigger:** Inventory releases a previously-held reservation as part of compensation.

```json
{
  "event_id": "a1b2c3d4-0008-4000-8000-000000000008",
  "event_type": "InventoryReleased",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:03Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "reservation_id": "res-55012",
    "items": [
      {
        "product_id": "prod-001",
        "quantity": 2
      },
      {
        "product_id": "prod-007",
        "quantity": 1
      }
    ],
    "reason": "Payment failed - releasing reserved stock"
  }
}
```

#### What happens in the service

This event is emitted when the Inventory service processes either a `PaymentFailed` or `PaymentRefunded` event. The logic is:

1. **Reservation lookup.** The service looks up the reservation record by `order_id` (or by the `reservation_id` if available from the triggering event's context). It verifies the reservation exists and is in `reserved` status.

2. **Stock increment.** For each item in the reservation, the service increments `available_stock` by the reserved `quantity`. This is a forward action - I am adding stock back, not rolling back a transaction.

3. **Reservation status update.** The reservation record is updated to status `released`. The original reservation row is never deleted - it stays in the database for the full audit trail. I can see that reservation `res-55012` was created at time T1 and released at time T2, which is valuable for debugging.

4. **Outbox insert.** The `InventoryReleased` event is inserted into the outbox within the same transaction that incremented stock and updated the reservation.

#### What consumers should do

**Order Service** (queue: `order.inventory.released`):
- This is the signal that the compensation chain is complete (or at least the inventory portion is). The Order service updates the order status to `cancelled`.
- Insert `OrderCancelled` into the outbox with a reason that reflects the root cause (e.g. "Payment failed - all compensations completed" or "Shipment failed - all compensations completed").
- Ack the message.

#### Edge cases and validation

- **Reservation not found.** If the Inventory service receives a compensation trigger (`PaymentFailed` or `PaymentRefunded`) but cannot find a reservation for the `order_id`, this means either (a) the reservation was already released (idempotency), or (b) the `OrderCreated` event was never successfully processed. In case (a), the idempotency check handles it. In case (b), there is nothing to release - the service should ack and emit a minimal `InventoryReleased` event (or simply not emit one, since there is nothing to compensate).
- **Double release.** If both `PaymentFailed` and `PaymentRefunded` arrive for the same order (which should not happen in normal flow but could happen due to a bug), the second one should be a no-op. The reservation is already in `released` status, so the stock increment should not happen again. This is a business-level idempotency check beyond the `event_id` check.
- **Stock exceeding original levels.** After release, `available_stock` should not exceed the original stock level before the reservation. In practice, since I am incrementing by exactly the reserved quantity, this arithmetic is correct. But if a bug caused a double release, stock could be artificially inflated. The reservation status check (`WHERE status = 'reserved'`) prevents this.

#### Design notes

- **This is a forward action, not a rollback.** I want to emphasize this because it is the philosophical core of the saga pattern. I am not issuing `ROLLBACK` to the database. I am performing a new, independent business operation: "release stock." This operation is recorded, auditable, and produces its own event. The original reservation still exists in the database with status `reserved` (now updated to `released`). If I ever need to audit what happened, I can see the full lifecycle: reserved at T1, released at T2, for reason X.
- **`reason` field tells the story.** The `reason` field carries the narrative of why the stock is being released. This is invaluable when looking at the Saga Trace Dashboard - seeing "Payment failed - releasing reserved stock" immediately tells me the root cause without needing to trace back through the event chain.
- **Items array is a copy, not a reference.** I include the full list of items and quantities being released, even though this data is a copy of what was in `InventoryReserved`. I could have omitted it and said "look up the reservation by `reservation_id`," but including it makes the event self-contained. Any consumer or observer can understand what happened without querying another service's database.

---

### 9. `PaymentRefunded`

**Producer:** Payment Service
**Routing Key:** `payment.refunded`
**Consumers:** Inventory Service, Order Service
**Trigger:** Payment service issues a refund as part of compensation (e.g. after `ShipmentFailed`).

```json
{
  "event_id": "a1b2c3d4-0009-4000-8000-000000000009",
  "event_type": "PaymentRefunded",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:04Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "payment_id": "pay-78301",
    "refund_id": "ref-91204",
    "amount_cents": 6200,
    "currency": "USD",
    "reason": "Shipment failed - refunding customer"
  }
}
```

#### What happens in the service

This event is emitted when the Payment service processes a `ShipmentFailed` event. The logic is:

1. **Payment lookup.** The service looks up the payment record for this `order_id`. It verifies the payment is in `charged` status - you can only refund a charge that actually went through.

2. **Refund execution.** The service calls the payment provider's refund API for the full `amount_cents`. In a real system, this would be something like `stripe.refunds.create({ payment_intent: pay-78301, amount: 6200 })`.

3. **Record creation.** A new refund record is created with a unique `refund_id`, linking it to the original `payment_id`. The payment record is updated to status `refunded`.

4. **Outbox insert.** The `PaymentRefunded` event is inserted into the outbox within the same transaction that created the refund record and updated the payment status.

Similar to the charge flow, the external refund API call happens outside the database transaction. If the service crashes after the provider processes the refund but before the outbox insert commits, I have refunded the customer but not emitted the event. The downstream compensation (inventory release) would not trigger. This is why a reconciliation/cleanup job is essential in production.

#### What consumers should do

**Inventory Service** (queue: `inventory.payment.refunded`):
- This tells the Inventory service that the payment has been refunded, and it should now release the reserved stock.
- The logic is identical to how it handles `PaymentFailed`: look up the reservation, increment stock, mark reservation as released, emit `InventoryReleased`.
- The reason in the emitted `InventoryReleased` event will differ (e.g. "Shipment failed, payment refunded - releasing reserved stock") but the mechanics are the same.

**Order Service** (queue: `order.payment.refunded`):
- The Order service records the refund details on the order (refund ID, amount) for customer visibility.
- As with `PaymentFailed` and `ShipmentFailed`, the Order service does not emit `OrderCancelled` yet - it waits for `InventoryReleased` to confirm that the full compensation chain is complete.
- The Order service might update to an intermediate status like `refunded` for customer-facing queries.

#### Edge cases and validation

- **Partial refunds.** In this design, refunds are always for the full order amount. I do not support partial refunds because the saga does not support partial fulfillment. If I later add partial fulfillment, the refund logic and the event payload would need to change to include per-item refund amounts.
- **Refund exceeds original charge.** The `amount_cents` in the refund event should exactly match the `amount_cents` in the original `PaymentCharged` event. If there is a mismatch, it indicates a bug. The Payment service should validate this before executing the refund.
- **Provider refund delay.** Some payment providers process refunds asynchronously - the refund API returns success, but the money takes 5-10 business days to appear in the customer's account. My `PaymentRefunded` event means "the refund has been initiated," not "the money is back in the customer's account." This distinction matters for customer support messaging.
- **Inventory service receives `PaymentRefunded` but already released stock from `PaymentFailed`.** This should not happen in normal flow (a payment either fails or is refunded, not both), but if both events somehow arrive, the idempotency check on the reservation status (`WHERE status = 'reserved'`) prevents double release.

#### Design notes

- **`refund_id` is separate from `payment_id`.** The refund is a new financial record, not a modification of the original payment. This mirrors how payment providers work - Stripe creates a separate Refund object linked to the original PaymentIntent. My data model follows the same pattern.
- **Two consumers, same pattern as `PaymentFailed`.** Both `PaymentFailed` and `PaymentRefunded` trigger inventory release. The Inventory service does not care _why_ it should release stock - it just needs to know that it should. I could have unified these into a single routing key that the Inventory service listens to, but keeping them separate preserves the semantic meaning in the event log and makes the Saga Trace Dashboard more informative.
- **`reason` provides saga narrative continuity.** The reason "Shipment failed - refunding customer" connects this event to the `ShipmentFailed` event that triggered it. When reading the saga timeline, this creates a clear cause-and-effect chain without requiring the reader to infer the causal relationship.

---

## Terminal Events

### 10. `OrderCompleted`

**Producer:** Order Service
**Routing Key:** `order.completed`
**Consumers:** (Saga Trace Dashboard only)
**Trigger:** Order service receives `ShipmentCreated` and marks the order as `completed`.

```json
{
  "event_id": "a1b2c3d4-0010-4000-8000-000000000010",
  "event_type": "OrderCompleted",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:04Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "final_status": "completed"
  }
}
```

#### What happens in the service

When the Order service receives a `ShipmentCreated` event, the following logic runs:

1. **State validation.** The service verifies the order is currently in `pending` status (or an intermediate status like `payment_charged`). If the order is already `completed` or `cancelled`, this is a no-op - the idempotency check handles it.

2. **Status update.** The order status is updated to `completed` in `order_db`. Any additional metadata from the `ShipmentCreated` event (tracking number, estimated delivery) is stored on the order record.

3. **Outbox insert.** The `OrderCompleted` event is inserted into the outbox. This event has no functional consumers in the current system - no service reacts to it by doing work. But it is published for two important reasons: (a) the Saga Trace Dashboard needs it to mark the saga as successfully concluded, and (b) future consumers (e.g. a notification service that sends a "your order is on its way" email) can bind to `order.completed` without any changes to the Order service.

#### What consumers should do

**Saga Trace Dashboard** (queue: `trace.all`, bound to `#`):
- Record the event in the `event_trace` table.
- Mark the saga (identified by `correlation_id`) as successfully completed.
- Calculate and record the total saga duration (from the `OrderCreated` event's `occurred_at` to this event's `occurred_at`).

No other service has functional work to do with this event today. But I publish it anyway because in choreography, events are the communication mechanism - if I do not publish the terminal state, it is invisible outside the Order service's database.

#### Edge cases and validation

- **Order already completed.** Duplicate delivery of `ShipmentCreated` could trigger a second `OrderCompleted`. The idempotency check on the `ShipmentCreated` event's `event_id` prevents this. Even if it got through, emitting `OrderCompleted` twice is harmless - it is an idempotent state transition.
- **Order in cancelled state receives `ShipmentCreated`.** This would be a bug in the saga flow (how can a shipment be created for a cancelled order?). The Order service should log a critical warning, ack the message, and not change the order status. `cancelled` is a terminal state and should not be overridden.
- **Saga Trace Dashboard is down.** Since the dashboard is the only consumer, if it is down when `OrderCompleted` is published, the event sits in the `trace.all` queue until the dashboard comes back. This is fine - the order is still completed, and the dashboard just catches up later. This is a key benefit of durable queues.

#### Design notes

- **Minimal payload.** This event carries only `order_id` and `final_status`. I do not repeat the items, amounts, or tracking number because they are all available in earlier events in the saga timeline. Anyone who needs the full picture can reconstruct it from the event chain using the `correlation_id`.
- **`final_status` is explicit.** I include `final_status: "completed"` even though the event type `OrderCompleted` already implies it. This is for consumers that process multiple event types with a single handler - they can switch on `final_status` without needing to map event types to statuses.
- **This is a "bookend" event.** `OrderCreated` opens the saga, `OrderCompleted` closes it. Together, they define the happy path boundary. Every other event in the saga falls between these two.

---

### 11. `OrderCancelled`

**Producer:** Order Service
**Routing Key:** `order.cancelled`
**Consumers:** (Saga Trace Dashboard only)
**Trigger:** Order service determines the saga has been fully compensated and marks the order as `cancelled`.

```json
{
  "event_id": "a1b2c3d4-0011-4000-8000-000000000011",
  "event_type": "OrderCancelled",
  "event_version": 1,
  "correlation_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "occurred_at": "2026-07-31T17:00:05Z",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "reason": "Payment declined - all compensations completed",
    "final_status": "cancelled"
  }
}
```

#### What happens in the service

The Order service emits `OrderCancelled` in three different scenarios, each triggered by a different incoming event:

1. **After `InventoryReservationFailed`:** The simplest case. No stock was reserved, no payment was charged. The order goes directly from `pending` to `cancelled`. The `reason` reflects the inventory failure.

2. **After `InventoryReleased` (payment failure path):** Payment failed, stock was released. The order has gone through: `pending` -> (inventory reserved) -> (payment failed) -> (inventory released) -> `cancelled`. The `reason` reflects the payment failure as root cause.

3. **After `InventoryReleased` (shipment failure path):** Shipment failed, payment was refunded, stock was released. The order has gone through the longest compensation chain. The `reason` reflects the shipment failure as root cause.

In all three cases, the logic is:

1. **State validation.** Verify the order is not already in `cancelled` or `completed` status.
2. **Status update.** Update the order status to `cancelled` with the reason.
3. **Outbox insert.** Insert the `OrderCancelled` event into the outbox.

The key insight is that the Order service does not cancel the order the moment it hears about a failure. It waits for the compensation chain to complete. The signal that "compensation is done" depends on the failure path:
- Inventory failure: `InventoryReservationFailed` is the terminal signal (nothing to compensate).
- Payment failure: `InventoryReleased` is the terminal signal (stock was reserved, now released).
- Shipment failure: `InventoryReleased` is the terminal signal (stock was reserved, payment was refunded, stock released).

In both the payment and shipment failure paths, `InventoryReleased` is what triggers `OrderCancelled`. This is elegant but requires the Order service to know which compensation path it is on - I track this via the order's intermediate status.

#### What consumers should do

**Saga Trace Dashboard** (queue: `trace.all`, bound to `#`):
- Record the event in the `event_trace` table.
- Mark the saga (identified by `correlation_id`) as completed with status `cancelled`.
- Record the `reason` for searchability and reporting.
- Calculate the total saga duration, including compensation time.

Like `OrderCompleted`, this event has no functional consumers today. I publish it so the saga has a clear terminal event visible to any observer.

#### Edge cases and validation

- **Multiple cancellation triggers.** In the shipment failure path, the Order service might receive `ShipmentFailed`, `PaymentRefunded`, and `InventoryReleased` - all of which could theoretically trigger cancellation. But the Order service only cancels on `InventoryReleased` (the last step in the compensation chain). The other events update intermediate state but do not trigger the terminal transition. This prevents duplicate `OrderCancelled` events.
- **Order already completed.** If the Order service somehow receives `InventoryReleased` for an order that is already `completed`, something has gone seriously wrong in the saga flow. The service should log a critical error, ack the message, and not change the status. This is a "should never happen" scenario that I still handle defensively.
- **Reason clarity.** The `reason` field should reflect the original root cause, not the immediate trigger. "Payment declined - all compensations completed" is better than "Inventory released" because the customer (and the support agent) cares about why the order failed, not which internal service event triggered the status change.

#### Design notes

- **`reason` is in this event but not in `OrderCompleted`.** Successful orders do not need a reason - they succeeded. Failed orders always need a reason because "your order was cancelled" without explanation is unacceptable. This asymmetry in the payload shape is intentional.
- **`final_status` mirrors `OrderCompleted`.** Both terminal events include `final_status` for consistency. A generic consumer that processes both can use the same field to determine the final outcome.
- **This event closes the saga.** Like `OrderCompleted`, `OrderCancelled` is a bookend. Together with `OrderCreated`, these three events define the saga lifecycle: started, succeeded, or failed. Every other event is an intermediate step.

---

## Consumer Binding Summary

This table shows which service listens to which routing keys, the queue name each consumer uses, and what action it takes. I can verify at a glance that every event has exactly the consumers it needs.

| Service | Binds To (Routing Key) | Queue Name | Reacts By |
|---|---|---|---|
| **Inventory** | `order.created` | `inventory.order.created` | Reserve stock -> emit `InventoryReserved` or `InventoryReservationFailed` |
| **Inventory** | `payment.failed` | `inventory.payment.failed` | Release stock -> emit `InventoryReleased` |
| **Inventory** | `payment.refunded` | `inventory.payment.refunded` | Release stock -> emit `InventoryReleased` |
| **Payment** | `inventory.reserved` | `payment.inventory.reserved` | Charge customer -> emit `PaymentCharged` or `PaymentFailed` |
| **Payment** | `shipment.failed` | `payment.shipment.failed` | Refund customer -> emit `PaymentRefunded` |
| **Shipping** | `payment.charged` | `shipping.payment.charged` | Create shipment -> emit `ShipmentCreated` or `ShipmentFailed` |
| **Order** | `inventory.reservation_failed` | `order.inventory.reservation_failed` | Mark order `cancelled` -> emit `OrderCancelled` |
| **Order** | `shipment.created` | `order.shipment.created` | Mark order `completed` -> emit `OrderCompleted` |
| **Order** | `inventory.released` | `order.inventory.released` | Mark order `cancelled` -> emit `OrderCancelled` |
| **Order** | `payment.failed` | `order.payment.failed` | Record failure reason (intermediate status, no terminal event) |
| **Order** | `shipment.failed` | `order.shipment.failed` | Record failure reason (intermediate status, no terminal event) |
| **Order** | `payment.refunded` | `order.payment.refunded` | Record refund details (intermediate status, no terminal event) |
| **Trace Dashboard** | `#` (all) | `trace.all` | Store event in `event_trace` for saga timeline reconstruction |

> **Note on Order service bindings:** The last three rows (order consuming `payment.failed`, `shipment.failed`, and `payment.refunded`) are not strictly necessary for the saga to function correctly. The Order service can complete its state machine using only `inventory.reservation_failed`, `shipment.created`, and `inventory.released`. But consuming the intermediate failure events lets the Order service show richer status information to the customer - "your payment was declined" instead of just waiting silently until "your order was cancelled."

---

## Event Flow Summary

This diagram shows how the 11 events connect the four services. Solid lines are happy path events, dashed lines are failure and compensation events.

![Event Flow](./Assets/eventFlow.svg)