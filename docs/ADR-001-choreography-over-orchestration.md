# ADR-001: Choreography over Orchestration

## Status
Accepted

## Context
I am building the Chorus event-driven order system, comprised of four distinct microservices (`order-service`, `inventory-service`, `payment-service`, `shipping-service`) written in three different languages/frameworks (Spring Boot, NestJS, Laravel). The overarching architectural challenge I face is how to coordinate a distributed transaction (the "Saga") across these services without a shared database.

There are two primary ways I could implement a Saga pattern:
1. **Orchestration**: A central orchestrator service coordinates the transaction by explicitly commanding each service what to do and rolling back if necessary.
2. **Choreography**: No central coordinator exists. Services react to domain events emitted by other services and emit their own events upon completion.

## Decision
I have deliberately chosen **Choreography** for this system.

![./Assets/Choreography.svg](./Assets/Choreography.svg)

## Consequences

**What I gain (Why I chose it):**
*   **Maximum Decoupling**: My services only know about the event contract (e.g., `OrderCreated`), not about each other. This makes the polyglot nature of my system (Java, Node.js, PHP) much safer, as I don't need RPC clients or shared libraries.
*   **Language-Agnostic Boundaries**: The event broker (RabbitMQ) simply routes JSON payloads. If my Spring Boot producer and my NestJS consumer correctly serialize/deserialize the same event, I have proven the integration boundary is clean.
*   **No Single Point of Failure/Bottleneck**: There is no orchestrator service that must scale with every single business process.
*   **Learning Value**: Choreography is notoriously harder to observe and debug. Solving these challenges (e.g., building a Saga Trace Dashboard, handling idempotency, race conditions, and eventual consistency) will force me to deeply learn distributed systems principles.

**What I give up (Trade-offs):**
*   **Observability**: It is difficult to see the state of a full transaction out-of-the-box. I will mitigate this in a later phase by building a read-only aggregation trace dashboard.
*   **Testing Complexity**: Integration testing requires me to stand up multiple services and the broker to verify the end-to-end flow.
*   **Cyclic Dependencies Risk**: Without a strict event design, my services can end up in infinite loops reacting to each other's events. I must carefully design the event shape and compensation chains to prevent this.

## Implementation Notes
To ensure my choreography is robust:
*   I will use the **Transactional Outbox** pattern to guarantee that my business state changes and outgoing events are atomically persisted.
*   All my consumers will be **Idempotent**, checking a local `processed_events` table before acting, to handle at-least-once delivery semantics from RabbitMQ.
*   I will rely on **Forward Recovery (Compensating Transactions)** rather than traditional database rollbacks.
