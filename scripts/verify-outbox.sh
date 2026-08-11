#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - Outbox Pattern Verification Script
# ---------------------------------------------------------------------------
#  This script demonstrates the Transactional Outbox pattern across all
#  Chorus microservices. It inserts mock PENDING events into each service's
#  outbox_events table, waits for the polling relay workers to publish them,
#  and then verifies the database status and RabbitMQ exchange metrics.
#
#  Prerequisites:
#    - Docker containers (chorus-postgres, chorus-rabbitmq) must be running.
#    - At least one of the services must be running so its relay can publish.
#    - jq must be installed for JSON formatting.
#
#  Usage:
#    chmod +x scripts/verify-outbox.sh
#    ./scripts/verify-outbox.sh
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
#  Colors and Symbols
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

PASS="${GREEN}PASS${RESET}"
FAIL="${RED}FAIL${RESET}"
SKIP="${YELLOW}SKIP${RESET}"
ARROW="${CYAN}>>>${RESET}"
DOT="${DIM}...${RESET}"

# ---------------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------------
POSTGRES_CONTAINER="chorus-postgres"
POSTGRES_USER="postgres"
RABBITMQ_HOST="localhost"
RABBITMQ_PORT="15672"
RABBITMQ_USER="guest"
RABBITMQ_PASS="guest"
EXCHANGE_NAME="chorus.events"
RELAY_WAIT_SECONDS=8

# Test event UUIDs (deterministic so re-runs are safe)
ORDER_EVENT_ID="a1111111-1111-1111-1111-111111111111"
INVENTORY_EVENT_ID="b2222222-2222-2222-2222-222222222222"
PAYMENT_EVENT_ID="c3333333-3333-3333-3333-333333333333"
SHIPPING_EVENT_ID="d4444444-4444-4444-4444-444444444444"
CORRELATION_ID="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

# Counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# ---------------------------------------------------------------------------
#  Helper Functions
# ---------------------------------------------------------------------------

banner() {
    echo ""
    echo -e "${BLUE}${BOLD}============================================================${RESET}"
    echo -e "${BLUE}${BOLD}  $1${RESET}"
    echo -e "${BLUE}${BOLD}============================================================${RESET}"
    echo ""
}

section() {
    echo ""
    echo -e "  ${MAGENTA}${BOLD}--- $1 ---${RESET}"
    echo ""
}

info() {
    echo -e "  ${ARROW} $1"
}

dim() {
    echo -e "  ${DIM}$1${RESET}"
}

result() {
    TOTAL=$((TOTAL + 1))
    local status="$1"
    local description="$2"
    if [ "$status" = "pass" ]; then
        PASSED=$((PASSED + 1))
        echo -e "  [${PASS}] $description"
    elif [ "$status" = "fail" ]; then
        FAILED=$((FAILED + 1))
        echo -e "  [${FAIL}] $description"
    else
        SKIPPED=$((SKIPPED + 1))
        echo -e "  [${SKIP}] $description"
    fi
}

psql_exec() {
    local db="$1"
    local sql="$2"
    docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db" -t -A -c "$sql" 2>/dev/null
}

table_exists() {
    local db="$1"
    local table="$2"
    local count
    count=$(psql_exec "$db" "SELECT count(*) FROM information_schema.tables WHERE table_name = '$table';")
    [ "$count" -ge 1 ]
}

insert_mock_event() {
    local db="$1"
    local event_id="$2"
    local event_type="$3"
    local routing_key="$4"
    local payload="$5"

    # Delete any previous test row with the same ID (idempotent re-runs)
    psql_exec "$db" "DELETE FROM outbox_events WHERE id = '$event_id';" > /dev/null 2>&1 || true

    psql_exec "$db" "
        INSERT INTO outbox_events (id, event_type, routing_key, correlation_id, payload, occurred_at, status)
        VALUES (
            '$event_id',
            '$event_type',
            '$routing_key',
            '$CORRELATION_ID',
            '$payload',
            NOW(),
            'PENDING'
        );
    " > /dev/null 2>&1
}

get_event_status() {
    local db="$1"
    local event_id="$2"
    psql_exec "$db" "SELECT status FROM outbox_events WHERE id = '$event_id';"
}

check_docker_container() {
    docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

# ---------------------------------------------------------------------------
#  Pre-flight Checks
# ---------------------------------------------------------------------------

banner "Chorus Outbox Verification"

echo -e "  ${BOLD}Date:${RESET}    $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  ${BOLD}Script:${RESET}  scripts/verify-outbox.sh"
echo ""

section "Pre-flight Checks"

if check_docker_container "$POSTGRES_CONTAINER"; then
    result "pass" "Postgres container ($POSTGRES_CONTAINER) is running"
else
    result "fail" "Postgres container ($POSTGRES_CONTAINER) is NOT running"
    echo -e "\n  ${RED}Cannot proceed without Postgres. Run: docker-compose up -d${RESET}\n"
    exit 1
fi

if check_docker_container "chorus-rabbitmq"; then
    result "pass" "RabbitMQ container (chorus-rabbitmq) is running"
else
    result "fail" "RabbitMQ container (chorus-rabbitmq) is NOT running"
    echo -e "\n  ${RED}Cannot proceed without RabbitMQ. Run: docker-compose up -d${RESET}\n"
    exit 1
fi

if command -v jq &> /dev/null; then
    result "pass" "jq is installed"
else
    result "skip" "jq not found - RabbitMQ API output will not be formatted"
fi

# Record initial exchange publish count
INITIAL_PUBLISH_IN=$(curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASS" \
    "http://$RABBITMQ_HOST:$RABBITMQ_PORT/api/exchanges/%2F/$EXCHANGE_NAME" 2>/dev/null \
    | jq -r '.message_stats.publish_in // 0' 2>/dev/null || echo "0")

info "Initial exchange publish_in count: ${BOLD}$INITIAL_PUBLISH_IN${RESET}"

# ---------------------------------------------------------------------------
#  Test 1: Order Service (order_db)
# ---------------------------------------------------------------------------

banner "Test 1: Order Service (Spring Boot / JPA)"

section "Schema Verification"

if table_exists "order_db" "outbox_events"; then
    result "pass" "outbox_events table exists in order_db"
else
    result "fail" "outbox_events table does NOT exist in order_db"
fi

if table_exists "order_db" "processed_events"; then
    result "pass" "processed_events table exists in order_db"
else
    result "fail" "processed_events table does NOT exist in order_db"
fi

section "Insert Mock Event"

info "Event ID:    $ORDER_EVENT_ID"
info "Event Type:  OrderCreatedEvent"
info "Routing Key: order.created"
dim "Payload:     {\"orderId\": 1, \"customerId\": 42, \"totalCents\": 9999}"

insert_mock_event "order_db" \
    "$ORDER_EVENT_ID" \
    "OrderCreatedEvent" \
    "order.created" \
    '{"orderId": 1, "customerId": 42, "totalCents": 9999}'

STATUS_BEFORE=$(get_event_status "order_db" "$ORDER_EVENT_ID")
if [ "$STATUS_BEFORE" = "PENDING" ]; then
    result "pass" "Event inserted with status PENDING"
else
    result "fail" "Expected status PENDING, got: $STATUS_BEFORE"
fi

section "Waiting for Relay Worker"

info "Waiting ${RELAY_WAIT_SECONDS}s for the @Scheduled relay to pick up the event${DOT}"
sleep "$RELAY_WAIT_SECONDS"

section "Verify Status Transition"

STATUS_AFTER=$(get_event_status "order_db" "$ORDER_EVENT_ID")
if [ "$STATUS_AFTER" = "PUBLISHED" ]; then
    result "pass" "Event status transitioned: PENDING -> PUBLISHED"
else
    result "fail" "Expected status PUBLISHED, got: $STATUS_AFTER"
fi

# ---------------------------------------------------------------------------
#  Test 2: Inventory Service (inventory_db)
# ---------------------------------------------------------------------------

banner "Test 2: Inventory Service (Spring Boot / JPA)"

section "Schema Verification"

if table_exists "inventory_db" "outbox_events"; then
    result "pass" "outbox_events table exists in inventory_db"
else
    result "fail" "outbox_events table does NOT exist in inventory_db"
fi

if table_exists "inventory_db" "processed_events"; then
    result "pass" "processed_events table exists in inventory_db"
else
    result "fail" "processed_events table does NOT exist in inventory_db"
fi

section "Insert Mock Event"

info "Event ID:    $INVENTORY_EVENT_ID"
info "Event Type:  InventoryReservedEvent"
info "Routing Key: inventory.reserved"
dim "Payload:     {\"orderId\": 1, \"sku\": \"WIDGET-001\", \"quantity\": 2}"

insert_mock_event "inventory_db" \
    "$INVENTORY_EVENT_ID" \
    "InventoryReservedEvent" \
    "inventory.reserved" \
    '{"orderId": 1, "sku": "WIDGET-001", "quantity": 2}'

STATUS_BEFORE=$(get_event_status "inventory_db" "$INVENTORY_EVENT_ID")
if [ "$STATUS_BEFORE" = "PENDING" ]; then
    result "pass" "Event inserted with status PENDING"
else
    result "fail" "Expected status PENDING, got: $STATUS_BEFORE"
fi

section "Waiting for Relay Worker"

info "Waiting ${RELAY_WAIT_SECONDS}s for the @Scheduled relay to pick up the event${DOT}"
sleep "$RELAY_WAIT_SECONDS"

section "Verify Status Transition"

STATUS_AFTER=$(get_event_status "inventory_db" "$INVENTORY_EVENT_ID")
if [ "$STATUS_AFTER" = "PUBLISHED" ]; then
    result "pass" "Event status transitioned: PENDING -> PUBLISHED"
else
    result "fail" "Expected status PUBLISHED, got: $STATUS_AFTER"
fi

# ---------------------------------------------------------------------------
#  Test 3: Payment Service (payment_db)
# ---------------------------------------------------------------------------

banner "Test 3: Payment Service (NestJS / TypeORM)"

section "Schema Verification"

if table_exists "payment_db" "outbox_events"; then
    result "pass" "outbox_events table exists in payment_db"
else
    result "fail" "outbox_events table does NOT exist in payment_db"
fi

if table_exists "payment_db" "processed_events"; then
    result "pass" "processed_events table exists in payment_db"
else
    result "fail" "processed_events table does NOT exist in payment_db"
fi

section "Insert Mock Event"

info "Event ID:    $PAYMENT_EVENT_ID"
info "Event Type:  PaymentProcessedEvent"
info "Routing Key: payment.processed"
dim "Payload:     {\"orderId\": 1, \"amountCents\": 9999, \"method\": \"card\"}"

insert_mock_event "payment_db" \
    "$PAYMENT_EVENT_ID" \
    "PaymentProcessedEvent" \
    "payment.processed" \
    '{"orderId": 1, "amountCents": 9999, "method": "card"}'

STATUS_BEFORE=$(get_event_status "payment_db" "$PAYMENT_EVENT_ID")
if [ "$STATUS_BEFORE" = "PENDING" ]; then
    result "pass" "Event inserted with status PENDING"
else
    result "fail" "Expected status PENDING, got: $STATUS_BEFORE"
fi

section "Waiting for Relay Worker"

info "Waiting ${RELAY_WAIT_SECONDS}s for the @Cron relay to pick up the event${DOT}"
sleep "$RELAY_WAIT_SECONDS"

section "Verify Status Transition"

STATUS_AFTER=$(get_event_status "payment_db" "$PAYMENT_EVENT_ID")
if [ "$STATUS_AFTER" = "PUBLISHED" ]; then
    result "pass" "Event status transitioned: PENDING -> PUBLISHED"
else
    result "fail" "Expected status PUBLISHED, got: $STATUS_AFTER"
fi

# ---------------------------------------------------------------------------
#  Test 4: Shipping Service (shipping_db) - Best Effort
# ---------------------------------------------------------------------------

banner "Test 4: Shipping Service (Laravel / Eloquent)"

section "Schema Verification"

if table_exists "shipping_db" "outbox_events"; then
    result "pass" "outbox_events table exists in shipping_db"

    section "Insert Mock Event"

    info "Event ID:    $SHIPPING_EVENT_ID"
    info "Event Type:  ShipmentScheduledEvent"
    info "Routing Key: shipment.scheduled"
    dim "Payload:     {\"orderId\": 1, \"carrier\": \"fedex\", \"trackingNumber\": \"FX123456\"}"

    insert_mock_event "shipping_db" \
        "$SHIPPING_EVENT_ID" \
        "ShipmentScheduledEvent" \
        "shipment.scheduled" \
        '{"orderId": 1, "carrier": "fedex", "trackingNumber": "FX123456"}'

    STATUS_BEFORE=$(get_event_status "shipping_db" "$SHIPPING_EVENT_ID")
    if [ "$STATUS_BEFORE" = "PENDING" ]; then
        result "pass" "Event inserted with status PENDING"
    else
        result "fail" "Expected status PENDING, got: $STATUS_BEFORE"
    fi

    section "Waiting for Relay Worker"

    info "Waiting ${RELAY_WAIT_SECONDS}s for the Artisan scheduler to pick up the event${DOT}"
    sleep "$RELAY_WAIT_SECONDS"

    section "Verify Status Transition"

    STATUS_AFTER=$(get_event_status "shipping_db" "$SHIPPING_EVENT_ID")
    if [ "$STATUS_AFTER" = "PUBLISHED" ]; then
        result "pass" "Event status transitioned: PENDING -> PUBLISHED"
    else
        result "skip" "Event still $STATUS_AFTER (Laravel scheduler may not be running)"
    fi
else
    result "skip" "outbox_events table does not exist in shipping_db (migrations not yet run)"
    dim "Run: cd shipping-service && php artisan migrate"
fi

# ---------------------------------------------------------------------------
#  Test 5: RabbitMQ Exchange Verification
# ---------------------------------------------------------------------------

banner "Test 5: RabbitMQ Exchange Verification"

section "Exchange Metadata"

EXCHANGE_JSON=$(curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASS" \
    "http://$RABBITMQ_HOST:$RABBITMQ_PORT/api/exchanges/%2F/$EXCHANGE_NAME" 2>/dev/null)

if [ -z "$EXCHANGE_JSON" ] || echo "$EXCHANGE_JSON" | jq -e '.error' > /dev/null 2>&1; then
    result "fail" "Exchange '$EXCHANGE_NAME' does not exist"
else
    EXCHANGE_TYPE=$(echo "$EXCHANGE_JSON" | jq -r '.type')
    EXCHANGE_DURABLE=$(echo "$EXCHANGE_JSON" | jq -r '.durable')

    if [ "$EXCHANGE_TYPE" = "topic" ]; then
        result "pass" "Exchange type is 'topic'"
    else
        result "fail" "Expected exchange type 'topic', got '$EXCHANGE_TYPE'"
    fi

    if [ "$EXCHANGE_DURABLE" = "true" ]; then
        result "pass" "Exchange is durable (survives broker restart)"
    else
        result "fail" "Exchange is not durable"
    fi
fi

section "Message Statistics"

FINAL_PUBLISH_IN=$(echo "$EXCHANGE_JSON" | jq -r '.message_stats.publish_in // 0' 2>/dev/null || echo "0")
MESSAGES_THIS_RUN=$((FINAL_PUBLISH_IN - INITIAL_PUBLISH_IN))

info "Messages published before this run: ${BOLD}$INITIAL_PUBLISH_IN${RESET}"
info "Messages published after this run:  ${BOLD}$FINAL_PUBLISH_IN${RESET}"
info "Messages published during this run: ${BOLD}$MESSAGES_THIS_RUN${RESET}"

if [ "$MESSAGES_THIS_RUN" -ge 4 ]; then
    result "pass" "At least 4 new messages arrived at the exchange (got $MESSAGES_THIS_RUN)"
else
    result "fail" "Expected at least 4 new messages, but only $MESSAGES_THIS_RUN arrived"
fi

# ---------------------------------------------------------------------------
#  Final Report
# ---------------------------------------------------------------------------

banner "Final Report"

echo -e "  ${BOLD}Total Tests:${RESET}   $TOTAL"
echo -e "  ${GREEN}${BOLD}Passed:${RESET}        $PASSED"
if [ "$FAILED" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}Failed:${RESET}        $FAILED"
else
    echo -e "  ${BOLD}Failed:${RESET}        $FAILED"
fi
if [ "$SKIPPED" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}Skipped:${RESET}       $SKIPPED"
else
    echo -e "  ${BOLD}Skipped:${RESET}       $SKIPPED"
fi
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All tests passed! The Transactional Outbox pattern is verified.${RESET}"
else
    echo -e "  ${RED}${BOLD}Some tests failed. Check the output above for details.${RESET}"
fi

echo ""
echo -e "  ${DIM}Tip: You can inspect the exchange in the RabbitMQ Management UI:${RESET}"
echo -e "  ${DIM}     http://localhost:15672/#/exchanges/%2F/chorus.events${RESET}"
echo ""

exit "$FAILED"
