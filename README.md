# Chorus

### Event-Driven Microservices with Choreographed Saga Pattern

I built this production-grade distributed order management system to demonstrate my mastery of event-driven architecture, saga patterns, and distributed systems engineering. I created four independently-owned microservices that coordinate purely through domain events on RabbitMQ. There is no central orchestrator, no shared databases, and no RPC.

---

## Architecture

![System Overview](docs/Assets/System_Overview.png)

### RabbitMQ Topology
![RabbitMQ Queues](docs/Assets/RabbitMQ_Queues.png)

### Idempotency & Rollback
![Idempotent Consumer](docs/Assets/Idempotent_Consumer.svg)
![Idempotency Rollback](docs/Assets/idompotencyRollback.svg)

> If you want to see the full visual breakdown (12 diagrams), check out [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Why I Built This Project

I built this system to answer a specific engineering question: **how do I coordinate a multi-step business transaction across independent services without a central orchestrator, without losing messages, and without duplicating side effects?**

The answer I came up with is a Choreographed Saga using:
- **Transactional Outbox**: zero message loss, no dual-write risk.
- **Idempotent Consumers**: exactly-once semantics on at-least-once delivery.
- **Compensating Transactions**: forward-recovery instead of rollback.
- **Dead-Letter Queues**: poison message isolation.
- **Strict State Machine**: race condition prevention.
- **Chaos Testing**: crash-and-recover resilience proof.

---

## My Tech Stack (Deliberately Polyglot)

| Service | Stack | Port | Why I chose it |
|---|---|---|---|
| **Order** | Java 21 / Spring Boot 3.4 | 8081 | It owns correlation IDs, terminal state, and trace aggregation. It's my most transaction-sensitive service. |
| **Inventory** | Java 21 / Spring Boot 3.4 | 8082 | Handles atomic reservation logic (pessimistic locking). It must never be wrong. |
| **Payment** | TypeScript / NestJS 11 | 8083 | A self-contained, bounded context. It proves my pattern works seamlessly in a second language. |
| **Shipping** | PHP 8.2 / Laravel 11 | 8084 | Has the simplest business logic, making it the lowest-risk service for my third runtime. |

**Why did I make it polyglot?** In choreography, my services communicate only through JSON events on a broker. Showing that a Java consumer and a Node consumer can correctly interpret the same event envelope is *proof* that my API boundary is clean, not just claimed. This wouldn't work in a tightly-coupled architecture; it's specifically choreography's decoupling that makes this safe.

---

## Event Catalog

The system coordinates via 11 strictly typed domain events across the `chorus.events` topic exchange.

| Event Type | Producer | Consumers | Payload Highlights |
|---|---|---|---|
| `OrderCreated` | Order | Inventory | `items`, `total_amount_cents` |
| `InventoryReserved` | Inventory | Payment, Order | `product_id`, `quantity` |
| `InventoryReservationFailed` | Inventory | Order | `reason` |
| `InventoryReleased` | Inventory | Order | `product_id`, `quantity` |
| `PaymentCharged` | Payment | Shipping, Order | `payment_id`, `amount_cents` |
| `PaymentFailed` | Payment | Inventory, Order | `reason`, `amount_cents` |
| `PaymentRefunded` | Payment | Inventory, Order | `refund_id`, `amount_cents` |
| `ShipmentCreated` | Shipping | Order | `tracking_number`, `courier` |
| `ShipmentFailed` | Shipping | Payment, Order | `reason` |
| `OrderCompleted` | Order | (None - Terminal) | `completed_at` |
| `OrderCancelled` | Order | (None - Terminal) | `reason` |

> See [docs/events.md](docs/events.md) for full JSON schemas.

![Event Flow](docs/Assets/eventFlow.svg)

---

## Saga State Machine

![State Diagram](docs/Assets/State_Diagram.svg)

---

## Event Flow (Happy Path)

![Happy Path Saga](docs/Assets/saga_happy_path.svg)

---

## Compensation Paths

When things go wrong, my saga compensates automatically via compensating domain events. There is no central rollback coordinator needed.

### 1. Inventory Failure
![Inventory Reservation Failure](docs/Assets/saga_inventory_reservation_failure.svg)

### 2. Payment Failure
![Payment Failure](docs/Assets/saga_payment_failure.svg)

### 3. Shipment Failure
![Shipment Failure](docs/Assets/saga_shipment_failure.svg)

---

## Running & Testing

### Getting Started

### Prerequisites

- Docker & Docker Compose
- Java 21+ (JDK)
- Node.js 18+
- PHP 8.2+ with Composer
- Maven (or use included `./mvnw`)

### 1. Start Infrastructure

```bash
docker-compose up -d
```

### 2. Start All Services

```bash
./start-all.sh
```

### 3. Create an Order

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "cust-1",
    "items": [{
      "productId": "prod-456",
      "quantity": 1,
      "unitPriceCents": 5000
    }]
  }' | jq
```

### 4. Trace the Saga

```bash
curl -s http://localhost:8081/api/orders/{orderId}/trace | jq
```

![Order Trace](docs/Assets/order_trace.svg)

---

### Functional & Chaos Testing Results

My testing suite rigorously validates exactly-once semantics, state consistency, and system recovery.

| Script | Category | What It Proves |
|---|---|---|
| `test-e2e-saga.sh` | **End-to-End** | Full happy path: Order → Inventory → Payment → Shipping → Completed. Verifies all 4 databases reach consistent terminal state. |
| `test-idempotent-consumers.sh` | **Exactly-Once** | Publishes duplicate events to all consumer queues. Verifies my `processed_events` table completely ignores duplicate processing. |
| `test-compensation-paths.sh` | **Compensation** | Triggers all 3 failure scenarios (inventory, payment, shipping) and verifies full rollback: stock restored, payments refunded, orders cancelled. |
| `test-race-condition.sh` | **Ordering** | Delivers `ShipmentFailed` before `PaymentCharged` is fully processed. Verifies my state machine rejects invalid out-of-order transitions. |
| `test-chaos.sh` | **Resilience** | **Chaos Test Result:** Crashes Payment Service mid-flight (after DB commit, but before RabbitMQ ACK). The un-acked message is redelivered on restart. The Idempotency check detects the duplicate, safely ACKs the message without processing, and the saga recovers 100% successfully. |
| `dlq-manager.sh` | **Observability** | CLI tool to inspect dead-lettered messages in `chorus.dlq` and replay them back to `chorus.events`. |

### Performance Benchmarks

For load testing and scaling behavior, see [docs/BENCHMARKS.md](docs/BENCHMARKS.md). 
The system handles up to 50x optimal load without losing a single order, gracefully degrading to the DLQ when HikariCP connection pools saturate. 

![Load Test](docs/Assets/Benchmarks/load_test.png)
![System Under Load](docs/Assets/Benchmarks/under_load.png)
![Exchange Under Load](docs/Assets/Benchmarks/exchange_under_load.png)
![Invariants Pass](docs/Assets/Benchmarks/invariants.png)

### Run Everything

```bash
# Functional tests
./scripts/test-e2e-saga.sh
./scripts/test-chaos.sh
./scripts/test-idempotent-consumers.sh
./scripts/test-compensation-paths.sh

# Performance benchmarks
./scripts/benchmark-saga-load.sh --run-all
./scripts/benchmark-invariants.sh
```

---

## Architecture Decision Records (ADRs)

I documented every major system design tradeoff in my ADRs:

| Document | Description |
|---|---|
| [ADR-001: Choreography over Orchestration](docs/ADR-001-choreography-over-orchestration.md) | **Decision:** Use event choreography without a central orchestrator. <br>**Why:** Maximizes service autonomy and prevents the orchestrator from becoming a single point of failure and bottleneck, despite the complexity of distributed tracing. |
| [ADR-002: Event Contract Shape](docs/ADR-002-event-contract-shape.md) | **Decision:** Use "Fat Events" with comprehensive JSON payloads and embedded correlation IDs. <br>**Why:** Eliminates the need for services to fetch state via synchronous REST calls after receiving an event, enforcing true decoupling. |
| [ADR-003: Idempotent Consumers](docs/ADR-003-Idempotent-Consumers.md) | **Decision:** Use a `processed_events` table with a unique constraint on `event_id` updated within the same local transaction as the business logic. <br>**Why:** RabbitMQ guarantees at-least-once delivery. This table converts it to exactly-once processing safely without distributed transactions. |
| [ADR-004: Compensation as Forward Action](docs/ADR-004-compensation-as-forward-action.md) | **Decision:** Model compensations (e.g. `PaymentRefunded`) as explicit forward-moving business events rather than hidden technical rollbacks. <br>**Why:** Makes rollback logic a first-class citizen in the domain, traceable and understandable to business stakeholders. |

---

## What I'd Do Differently at Scale

If I were taking this system from 5,000 orders/day to 50,000,000 orders/day, I would architecturally adapt the following:

1. **Replace Polling Outbox with CDC (Debezium):**
   Currently, a background thread polls the `outbox_events` table. At scale, this polling becomes a massive database bottleneck. I would replace it with **Debezium**, reading directly from Postgres WAL (Write-Ahead Logs) to stream events instantly into RabbitMQ (or Kafka) with near-zero database overhead.
2. **Migrate to Kafka for Replayability:**
   While RabbitMQ's topic exchanges are incredible for real-time routing, it lacks long-term retention. Kafka would allow me to onboard a new service (e.g., an Analytics service) and replay the last 6 months of historical events seamlessly.
3. **Partitioned/Sharded Databases:**
   The Inventory Service uses row-level pessimistic locking (`SELECT ... FOR UPDATE`), which would cause massive lock contention during high-velocity flash sales (e.g. Black Friday). I would move to an eventually-consistent ledger model for inventory, or shard the inventory database by `product_id`.
4. **Dedicated Orchestrator for Edge Cases (Temporal / AWS Step Functions):**
   Choreography is beautiful until the saga reaches 15+ steps and involves manual human interventions. At massive scale, I would migrate to an Orchestrated Saga (using Temporal.io) purely to get out-of-the-box saga timeouts, centralized workflow state, and simpler operational observability. 

---

## Project Structure

```
chorus/
├── order-service/          # Java 21 / Spring Boot 3.4
├── inventory-service/      # Java 21 / Spring Boot 3.4
├── payment-service/        # TypeScript / NestJS 11
├── shipping-service/       # PHP 8.2 / Laravel 11
├── postgres-init/          # Database initialization (4 isolated DBs)
├── scripts/                # Test suite, Chaos scripts, DLQ Manager
├── docs/                   # Architecture diagrams, ADRs, event catalog
├── docker-compose.yml      # RabbitMQ + PostgreSQL
└── start-all.sh            # Boot all services
```
