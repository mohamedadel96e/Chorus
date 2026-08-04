# ADR-002: Event Contract Shape

## Context

I need to define how my four services - Order (Spring Boot), Inventory (Spring Boot), Payment (NestJS), and Shipping (Laravel) - communicate through RabbitMQ. Since I chose choreography (ADR-001), these event contracts are the _only_ API boundary between services. There is no shared code, no shared types, no RPC - just JSON on a broker. Getting this shape wrong means every service is wrong, and fixing it later means coordinating changes across three languages and four codebases simultaneously.

## Design Decisions

I had three key design decisions to make, and each one has deeper implications than it initially appears:

1. **Fat events vs thin events** - should the event carry the full data a consumer needs, or just an ID that forces the consumer to call back for details?
2. **Correlation ID strategy** - how do I trace a single order's journey across four services, four databases, and eleven possible event types?
3. **Envelope structure** - what metadata does every event need regardless of business logic, and what format should each field use?

---

## Decision 1: Fat Events (Full Payload)

### The Thin Event Alternative I Rejected

A thin event for `OrderCreated` would look like this:

```json
{
  "event_type": "OrderCreated",
  "payload": {
    "order_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479"
  }
}
```

That is it. Just an ID. When the Inventory service receives this, it would need to make an HTTP call back to the Order service - something like `GET /orders/f47ac10b-58cc-4372-a567-0e02b2c3d479` - to fetch the item list, quantities, and pricing details it needs to actually reserve stock.

This looks clean on a whiteboard. In practice, it reintroduces exactly the coupling I chose choreography to avoid.

### Why Callbacks Defeat Choreography

The entire point of choosing choreography over orchestration (ADR-001) was to eliminate synchronous dependencies between my services. If Inventory must call Order's HTTP API to process an event, I have not built an event-driven architecture. I have built a request-driven architecture with extra steps.

Consider what this callback means concretely in my polyglot system: my Spring Boot Inventory service would need an HTTP client configured with the Order service's base URL. It would need to know Order's API contract - the endpoint path, the response shape, authentication headers if any, timeout settings, retry policies. It would need to handle every HTTP failure mode: connection refused, 404, 500, slow responses, timeouts. This is not a small amount of code. It is an entire synchronous integration layer bolted onto what was supposed to be an asynchronous, decoupled system.

Now multiply that by the NestJS Payment service (which would need to call back for pricing details) and the Laravel Shipping service (which would need customer address information). I would end up with three different HTTP client implementations across three languages, all calling the Order service, all needing to stay in sync with its API. That is the shared-library RPC world I specifically chose choreography to avoid.

### The Temporal Coupling Problem

Callbacks also create temporal coupling - the requirement that two services must be alive at the same time for work to proceed. This is the most insidious problem because it fails silently during development (when everything is running on your machine) and then explodes in production.

Here is the concrete scenario: the Order service creates an order, publishes `OrderCreated` to RabbitMQ, and then goes down for a deployment. Five seconds later, the Inventory service picks up the event from the queue, extracts the `order_id`, and attempts `GET /orders/{id}`. Connection refused. The Order service is not there.

What does Inventory do now? It cannot process the event because it does not have the data. It has three bad options:

1. **Reject and requeue the message.** Now the message sits in the queue, getting redelivered every few seconds, getting rejected every time, burning CPU and creating a thundering herd problem when Order comes back up. If Inventory has other events queued behind it, they are blocked too, creating head-of-line blocking.

2. **Send the message to the dead-letter queue.** Now I need manual intervention to replay it after Order recovers. If a hundred orders were created during the deployment window, I have a hundred DLQ messages to manually replay. This is an operational nightmare.

3. **Retry with exponential backoff.** Better, but now my "asynchronous" system has a consumer thread sitting idle for 30 seconds, 60 seconds, 2 minutes, waiting to make a synchronous call. If Order's deployment takes 5 minutes, my saga is stalled for 5 minutes. The whole point of asynchronous messaging was that the consumer processes events at its own pace without caring about the producer's availability.

With fat events, none of this matters. The event carries the data. RabbitMQ holds it durably. When Inventory picks it up - whether that is 100 milliseconds or 10 minutes after it was published - it has everything it needs. The Order service could be down for an hour and Inventory would process every queued event without noticing.

### The Data Snapshot Advantage

There is a subtler benefit that took me a while to appreciate: a fat event captures the state of the data at the exact moment the event occurred. This is not a limitation - it is actually what consumers need.

When the Order service publishes `OrderCreated`, the event contains the item list, quantities, and prices as they were at the moment the customer submitted the order. If the Order service later allowed order modifications (it does not in my design, but hypothetically), the state in the event would not match the current state in the Order database. With thin events and callbacks, Inventory would fetch the _current_ state, which might reflect modifications made after the event was published. It would be acting on data that does not correspond to the event it received.

This is the same reason financial systems use double-entry bookkeeping with immutable journal entries rather than mutable account balances. The historical record of what happened at a specific point in time is the source of truth, not the current snapshot. My events are journal entries for a distributed transaction.

### When Thin Events Would Be the Right Choice

I want to be honest about when thin events are better, because my choice is not universally correct:

**Very large payloads.** If my events carried, say, a full product image catalog or a 10MB PDF invoice, putting that data in every event would be wasteful and would strain the broker. In those cases, an event carrying just an ID with a link to fetch the large data from a blob store makes sense. My events are 200 to 500 bytes - this concern does not apply.

**Data that consumers always need the latest version of.** If my consumer needed the customer's _current_ shipping address (which might have been updated after the order was placed), a fat event carrying the address from order creation time would be stale. The consumer would need to call back to get the latest. In my design, the order data is immutable once created - the items, quantities, and prices never change after `OrderCreated` is published. So staleness is not a concern; the snapshot in the event is the canonical truth.

**Very high fan-out with selective consumption.** If I had fifty consumers and each one only needed two fields from a hundred-field payload, sending the full payload to all fifty is wasteful. A thin event that lets each consumer fetch only what it needs could be more efficient. I have four services and each one uses most of the data in the events it consumes. This optimization does not apply.

### Why Fat Events Are Correct for My Specific Case

My order data is immutable once created. The items a customer ordered, the quantities, and the prices they were charged do not change after the fact. This is the strongest possible argument for fat events: the data in the event is not just a snapshot - it is the permanent, canonical record of what happened. There is no "stale data" concern because the data cannot become stale.

Combined with the polyglot nature of my system (three languages, no shared libraries), the temporal coupling risks (any callback means two services must be alive simultaneously), and the small payload sizes involved, fat events are clearly the right choice here.

---

## Decision 2: Correlation ID From Day One

### Distributed Tracing Without Correlation IDs

Imagine I skipped this field. A customer calls in: "My order from yesterday is stuck." I have an `order_id`. Now I need to figure out what happened.

I open the Order service's Postgres database. The order is in status `pending`. That tells me the saga did not complete, but not why. Did Inventory fail? Did it succeed and Payment fail? Did none of them receive the event at all?

I open the Inventory service's database and search its `outbox_events` table for any event whose JSON payload contains this `order_id`. I am doing a `LIKE '%f47ac10b%'` search across a JSON column because there is no indexed foreign key linking these events to the Order service's concept of an order. If the Inventory database is large, this query is slow. If the event payload structure varies, my text search might miss it.

I find an `InventoryReserved` event. Good - Inventory succeeded. Now I open the Payment service's database and do the same text search. I find nothing. Did Payment never receive the event? Or did it receive it and fail before inserting anything? I check RabbitMQ's management UI to see if there are messages stuck in a queue. But RabbitMQ does not keep delivered messages - once a consumer acks, the message is gone.

I am now joining evidence across four databases by hand, hoping timestamps roughly align, searching JSON columns with text patterns. This process takes 20 minutes for a single order. If I need to debug a pattern across hundreds of orders, it is effectively impossible.

This is not a hypothetical scenario. I have seen teams spend entire sprints building ad-hoc tooling to correlate events after the fact because they did not include a correlation ID from the start.

### How Correlation ID Propagation Works

The propagation is mechanical and follows a simple rule: the `correlation_id` is set once, at the origin, and every downstream service copies it verbatim into every event it produces for that saga.

Here is the exact flow:

1. **Order service creates the saga.** A customer calls `POST /orders`. The Order service generates a UUID v4 for the `order_id`. It sets `correlation_id = order_id` in the `OrderCreated` event and inserts both the order record and the outbox event in a single database transaction. At this point, the `correlation_id` `f47ac10b-58cc-4372-a567-0e02b2c3d479` is born.

2. **Inventory service receives `OrderCreated`.** It reads `correlation_id` from the incoming event envelope. When it inserts its own outbox event (`InventoryReserved` or `InventoryReservationFailed`), it copies this exact `correlation_id` value into the envelope of its outgoing event. It does not generate a new one. It does not modify it. It copies the bytes.

3. **Payment service receives `InventoryReserved`.** Same pattern. It reads the `correlation_id` from the incoming `InventoryReserved` event. When it produces `PaymentCharged` or `PaymentFailed`, it copies the same `correlation_id`. Payment does not know or care that this value originally came from the Order service two hops ago. It just propagates it.

4. **Shipping service receives `PaymentCharged`.** Same pattern. It copies the `correlation_id` into `ShipmentCreated` or `ShipmentFailed`.

5. **Order service receives the terminal event** (`ShipmentCreated`, `InventoryReleased`, etc.) and produces the final event (`OrderCompleted` or `OrderCancelled`) with the same `correlation_id`.

The result: every single event in a saga - whether it is the originating `OrderCreated`, a mid-chain `InventoryReserved`, a failure `PaymentFailed`, or a compensation `InventoryReleased` - carries the same `correlation_id`. A single `SELECT * FROM event_trace WHERE correlation_id = ?` query in the Saga Trace Dashboard reconstructs the entire saga timeline.

### Correlation ID vs OpenTelemetry Trace IDs

These two concepts solve different problems and operate at different layers, but people confuse them often enough that it is worth being explicit.

An **OpenTelemetry trace ID** tracks a single request through its execution path across services. When the Order service makes an HTTP call or processes a message, OpenTelemetry creates a trace with spans showing "Order service spent 5ms writing to the database, then 2ms publishing to RabbitMQ." If the Inventory service picks up that message, OpenTelemetry creates a new trace (or continues the existing one if you propagate trace context through message headers). The trace ID answers: "What did the system do to process _this specific operation_?"

A **correlation ID** ties together a multi-step business process that spans multiple independent operations over time. A saga might take 30 seconds from `OrderCreated` to `OrderCompleted`, during which five separate services process five separate messages. Each of those message-processing operations could have its own OpenTelemetry trace. The correlation ID answers: "What is the complete history of _this order_ across all services?"

In practice, a single saga like mine produces at least four OpenTelemetry traces (one per service processing step on the happy path), but only one correlation ID. The trace ID changes at each hop. The correlation ID stays the same from the first event to the last.

I will likely add OpenTelemetry instrumentation in a later phase, and when I do, I will propagate both the OTel trace context _and_ my `correlation_id` in the event headers. They will coexist without conflict because they answer different questions.

### Why I Set correlation_id = order_id

I made a deliberate choice to reuse the `order_id` as the `correlation_id` rather than generating a separate trace identifier. My reasoning:

**Conceptual alignment.** In my system, one order produces exactly one saga. There is no case where two orders share a saga or where one order spawns multiple sagas. The `order_id` _is_ the natural business key for the saga. Using it as the correlation ID means I never need a lookup table to map "trace ID X corresponds to order Y."

**Debugging convenience.** When a support request comes in, the engineer has an `order_id` from the customer. If `correlation_id` were a separate UUID, the engineer would first need to look up "what is the correlation ID for this order?" before querying the trace dashboard. With `correlation_id = order_id`, the customer's order ID is the direct query key. No indirection.

**Simplicity.** Generating a separate trace UUID, storing the mapping between it and the order, propagating both through events, and keeping them in sync adds complexity without benefit in my specific case. If I had sagas that spanned multiple orders - like a bulk order that triggers separate inventory reservations per warehouse - I would need a separate saga ID. I do not have that case.

The tradeoff: if I later introduce sagas that are not 1:1 with orders (e.g., a "return and exchange" saga that references both the original order and the new order), I will need to rethink this. For now, the simplicity wins.

---

## Decision 3: Standardized Envelope

Every event in the system conforms to this six-field envelope:

```json
{
  "event_id": "UUID v4 - unique per event, used for idempotency",
  "event_type": "PascalCase discriminator",
  "event_version": 1,
  "correlation_id": "UUID v4 - the original order ID",
  "occurred_at": "ISO 8601 timestamp",
  "payload": {}
}
```

Each field exists for a specific, non-obvious reason. I want to document those reasons because future-me (or a teammate) will inevitably ask "why not just..." about each one.

### Why event_id Is Separate From correlation_id

This distinction is critical and I have seen systems get it wrong by conflating the two.

The `correlation_id` identifies the _saga_ - the multi-step business process. Every event produced during the lifecycle of order `f47ac10b` carries the same `correlation_id`.

The `event_id` identifies _this specific event instance_. It is globally unique. No two events in the entire system will ever share an `event_id`.

Why does this matter? Because of idempotent consumers. Every consumer has a `processed_events` table where it records the `event_id` of every event it has successfully processed. Before acting on an incoming event, the consumer checks: "Have I already processed event `a1b2c3d4-0001`?" If yes, it skips it.

If I used `correlation_id` for idempotency, I would have a problem. A single saga produces many events: `OrderCreated`, `InventoryReserved`, `PaymentCharged`, `ShipmentCreated`, `OrderCompleted`. All of them carry the same `correlation_id`. If the Inventory service used `correlation_id` as its idempotency key, it would process `OrderCreated` and then skip `PaymentFailed` (which it also consumes) because it has already "seen" that `correlation_id`. The compensation would silently fail. This would be a catastrophic bug - money charged but inventory never released.

The `event_id` ensures each event is independently trackable for idempotency, while the `correlation_id` ties them all together for tracing. Two fields, two orthogonal purposes.

### Why event_version Exists

I could have skipped this field and added it when I actually need schema evolution. I chose not to, for a reason that comes from bitter experience: retrofitting versioning into existing events is painful.

If I ship v1 events without an `event_version` field, and then I add a `payment_method` field to `PaymentCharged` that the Shipping service's consumer does not understand, I have a problem. How does the consumer know whether the incoming event has `payment_method` or not? It cannot inspect a version number because there is none. It has to do defensive field-by-field checking: "Is `payment_method` present? If so, use it. If not, use default." This works for one added field. It becomes a maintenance nightmare when I am on the fifth iteration of schema changes and the consumer has a nested tree of "if field X exists, then also check for field Y, but only if field Z is absent..."

With `event_version` present from event number one, the consumer can cleanly branch:

```
if event_version == 1:
    // handle v1 shape
elif event_version == 2:
    // handle v2 shape with payment_method
```

The version field costs me 20 bytes per event. It saves me from a category of schema migration headaches that are hard to fix once you have events already persisted in outbox tables and trace logs.

### Why ISO 8601 Over Unix Epoch

Actually I've used it for debugging purposes. When I am investigating a stuck saga at midnight, I open the RabbitMQ management UI and look at a queued message. I see:

```
"occurred_at": "2026-07-31T17:00:02Z"
```

I immediately know this event happened at 5 PM UTC on July 31st. I can compare it to the event before it (`17:00:01Z`) and see there was a one-second gap. I can compare it to the current time and see the event has been sitting in the queue for three hours. All of this is instant, no conversion needed.

Now compare with a Unix epoch:

```
"occurred_at": 1785354002
```

What time is that? I have no idea without a converter. Is it seconds or milliseconds? (If it is 13 digits, milliseconds. If 10 digits, seconds. But I need to count the digits first.) What timezone am I in, and is the epoch UTC? How long ago was this event published? I need to subtract this number from the current epoch and convert the result to hours and minutes.

This is not a theoretical concern. I will be reading raw JSON events in broker UIs, log files, and database queries regularly. Every time I debug a timing issue, a message ordering problem, or a stuck saga, I will be comparing timestamps. ISO 8601 is self-documenting and human-readable. The extra bytes (30 bytes vs 10 bytes) are irrelevant at my scale.

I also chose ISO 8601 with explicit UTC designation (`Z` suffix) to avoid timezone ambiguity. If my Spring Boot service in one timezone publishes an epoch timestamp and my NestJS service in another timezone interprets it, they will agree because epoch is always UTC. But when I read the logs, I still cannot tell what time of day it was without converting. With ISO 8601 and explicit `Z`, both machine parsing and human reading are unambiguous.

### Why Integer Cents Over Decimal Numbers

This is not a stylistic preference. It prevents a class of bugs that are silent, rare, and devastating.

Consider the order total `$62.00`, which my Payment service needs to charge. Here is what happens in each language if I use decimal/float representation:

**Java (Spring Boot - Order and Inventory services):**
```java
// BigDecimal is exact but verbose
BigDecimal price = new BigDecimal("15.00");
BigDecimal qty = new BigDecimal("2");
BigDecimal subtotal = price.multiply(qty); // 30.00 - correct

// But if someone uses double instead of BigDecimal:
double price = 15.00;
double total = price * 2 + 32.00; // 62.0 - happens to be correct here
// Try: 0.1 + 0.2 = 0.30000000000000004 in IEEE 754
```

**TypeScript (NestJS - Payment service):**
```typescript
// JavaScript has no BigDecimal. All numbers are IEEE 754 doubles.
const price = 15.00;
const total = price * 2 + 32.00; // 62 - correct in this case
// But: 0.1 + 0.2 === 0.30000000000000004
// And: (0.1 + 0.2) === 0.3 is FALSE
```

**PHP (Laravel - Shipping service):**
```php
// PHP floats are IEEE 754 doubles, same as JavaScript
$price = 15.00;
$total = $price * 2 + 32.00; // 62.0 - correct here
// But: var_dump(0.1 + 0.2 == 0.3); // bool(false)
// And: intval((0.1 + 0.2) * 10); // 2, not 3!
```

The `0.1 + 0.2` problem is the classic example, but the real danger is subtler. It manifests when you serialize a decimal value in one language and deserialize it in another. Java's `BigDecimal("62.00")` serializes to JSON as `62.00`. JavaScript parses this as the IEEE 754 float `62`. Now imagine a more complex calculation where the result is `62.005` in BigDecimal but `62.00499999999999` in JavaScript's float. One service rounds to `$62.01`, the other to `$62.00`. You have a one-cent discrepancy that is invisible in testing (because your test cases use round numbers) and only appears in production with specific price combinations.

With integer cents, this entire problem category vanishes:

```json
{
  "amount_cents": 6200,
  "currency": "USD"
}
```

`6200` is an integer. Java, TypeScript, and PHP all represent integers exactly. There is no rounding. There is no precision loss. JSON serializes it as `6200` and every language deserializes it as exactly `6200`. The conversion to display format (`$62.00`) happens at the UI boundary, not in the event contract.

I include the `currency` field alongside the cents value because "6200 cents" is ambiguous without it - it could be USD, EUR, or JPY (where the smallest unit is actually 1 yen, not 1 cent). Even though my system currently only supports USD, including `currency` means I do not need a schema migration if I add multi-currency support later.

### Why I Do Not Include a source_service Field

Many event envelope designs include a field like `"source": "order-service"` or `"producer": "inventory"` to indicate which service emitted the event. I deliberately omitted this, and I want to explain why.

In a well-designed choreography, consumers should not care which service produced an event. They react to the event _type_, not the event _origin_. If my Inventory service receives a `PaymentFailed` event, it needs to release the reserved stock. It does not matter whether `PaymentFailed` was emitted by the Payment service, by a manual admin tool, or by a future fraud-detection service. The reaction is the same: release the stock.

Adding `source_service` creates the temptation to write conditional logic: "If this `PaymentFailed` came from the Payment service, release stock. If it came from the admin tool, do something different." This is the beginning of tight coupling through the back door. The consumer is now aware of the producer's identity, which means adding a new producer requires updating the consumer's branching logic.

**When I might add it:** if I build the Saga Trace Dashboard and find that I need to display which service produced each event for debugging purposes, I might add a `source_service` field to the envelope. But it would be metadata for humans, not routing logic for consumers. No consumer would branch on it. I would add it as an optional field with a default of `null` and backfill it in the trace dashboard's aggregation layer, not in the event contract itself.

---

## Saga Flow Diagrams

The following diagrams show every event exchange and the state transitions that occur at each step. I include state transitions because they are the mechanism that drives the saga forward - each service makes a local decision based on its current state and the incoming event, then emits a new event reflecting the result.

### Happy Path

The ideal flow where every step succeeds. The order moves through four states: `pending` -> `confirmed` -> `paid` -> `completed`.

![Saga Happy Path](./Assets/saga_happy_path.svg)

### Compensation Flow: Inventory Reservation Failure

The simplest failure case. Inventory cannot reserve stock (out of stock, discontinued product, etc.). No prior steps need undoing because nothing has been reserved or charged yet. The saga fails fast.

![Inventory Reservation Failure](./Assets/saga_inventory_reservation_failure.svg)

### Compensation Flow: Payment Failure

Payment fails after Inventory has already reserved stock. The reserved stock must be released - this is a forward compensating action (a new `InventoryReleased` event and corresponding database write), not a database rollback.

![Payment Failure](./Assets/saga_payment_failure.svg)

### Compensation Flow: Shipment Failure

The longest compensation chain - three steps must unwind in reverse order. The shipment failed after payment was charged and stock was reserved. Payment must refund, then Inventory must release, then Order must cancel. Each compensation step is a new forward action with its own event.

![Shipment Failure](./Assets/saga_shipment_failure.svg)

---

## Consequences

- The full event catalog with JSON examples, producer/consumer mappings, and routing key conventions is documented in [events.md](events.md). This ADR explains the _why_ behind those contracts; the event catalog is the _what_.

- **Every service must tolerate unknown fields** in event payloads from day one. This means no strict deserialization that throws on unexpected keys. When I add `payment_method` to `PaymentCharged` later, the Shipping service's consumer must not crash - it should simply ignore fields it does not recognize. This is the forward-compatibility guarantee that makes `event_version` useful rather than just a formality.

- **The `event_id` field is the foundation for idempotent consumers**. Every consumer will check its `processed_events` table for this ID before processing. Without unique `event_id` values, at-least-once delivery from RabbitMQ would cause duplicate processing - charging a customer twice, reserving stock twice, creating duplicate shipments.

- **Integer cents representation is non-negotiable** across all services. If any developer in any service introduces a floating-point money type in their local domain model, the serialization boundary will mask it as long as the JSON output is an integer. But internal calculations with floats will eventually produce rounding errors. Each service's code review checklist should include "no floating-point types for money."

- **Correlation ID propagation is every consumer's responsibility.** If any consumer forgets to copy the `correlation_id` from its incoming event to its outgoing event, the saga trace chain breaks. The Saga Trace Dashboard will have orphaned events with no `correlation_id` linking them to their saga. I should consider adding a unit test in each service that verifies: "for every incoming event type, the produced outgoing event carries the same `correlation_id`."
