#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - Idempotent Consumers Verification Script
# ---------------------------------------------------------------------------
#  This script verifies exactly-once processing (Phase 3). It publishes
#  duplicate events directly to RabbitMQ with the same event_id, and then
#  queries each microservice's processed_events table to ensure it was
#  only processed once.
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
PROCESS_WAIT_SECONDS=3

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

publish_event() {
    local routing_key=$1
    local payload=$2
    # Escape quotes for JSON payload string inside JSON body
    local escaped_payload=$(echo "$payload" | sed 's/"/\\"/g')
    
    curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" -H "content-type:application/json" \
         -X POST "http://${RABBITMQ_HOST}:${RABBITMQ_PORT}/api/exchanges/%2f/${EXCHANGE_NAME}/publish" \
         -d "{
               \"properties\":{\"content_type\":\"application/json\"},
               \"routing_key\":\"$routing_key\",
               \"payload\":\"$escaped_payload\",
               \"payload_encoding\":\"string\"
             }" > /dev/null
}

check_db_count() {
    local db_name=$1
    local event_id=$2
    
    # Temporarily disable pipefail because grep -c returns 1 if not found, crashing the script
    set +eo pipefail
    
    local query_out
    query_out=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db_name" -t -c "SELECT COUNT(*) FROM processed_events WHERE event_id = '$event_id';" 2>/dev/null)
    local query_code=$?
    
    set -eo pipefail
    
    if [ $query_code -ne 0 ]; then
        result "fail" "Could not connect to database $db_name (Docker exec failed)"
        return
    fi
    
    local count
    count=$(echo "$query_out" | xargs)
    count=${count:-0}
    
    if [ "$count" -eq 1 ]; then
        result "pass" "$db_name processed event exactly once! (Count: 1)"
    elif [ "$count" -gt 1 ]; then
        result "fail" "$db_name processed event multiple times! (Count: $count)"
    else
        result "skip" "$db_name has not processed the event yet. (Count: $count)"
        dim "Ensure the microservice is running and actively consuming."
    fi
}

# ---------------------------------------------------------------------------
#  Main Execution
# ---------------------------------------------------------------------------
banner "Chorus Idempotency Verification (Phase 3)"

CORRELATION_ID=$(uuidgen)
EVENT_INVENTORY=$(uuidgen)
EVENT_PAYMENT=$(uuidgen)
EVENT_SHIPPING=$(uuidgen)

info "Using Correlation ID: ${BOLD}$CORRELATION_ID${RESET}"

# 1. Inventory Service
section "1. Inventory Service (Spring Boot) - order.created"
PAYLOAD_1="{\"event_id\":\"$EVENT_INVENTORY\", \"correlation_id\":\"$CORRELATION_ID\", \"payload\": {\"order_id\":\"$CORRELATION_ID\", \"customer_id\":\"cust-idem-1\", \"total_amount_cents\":1000, \"items\":[{\"product_id\":\"prod-idem-1\", \"quantity\":1, \"unit_price_cents\":1000}]}}"
dim "Publishing initial event_id: $EVENT_INVENTORY"
publish_event "order.created" "$PAYLOAD_1"
sleep 1
dim "Publishing EXACT DUPLICATE event_id..."
publish_event "order.created" "$PAYLOAD_1"

# 2. Payment Service
section "2. Payment Service (NestJS) - inventory.reserved"
PAYLOAD_2="{\"event_id\":\"$EVENT_PAYMENT\", \"correlation_id\":\"$CORRELATION_ID\", \"payload\": {\"order_id\":\"$CORRELATION_ID\", \"total_amount_cents\":1000, \"currency\":\"USD\"}}"
dim "Publishing initial event_id: $EVENT_PAYMENT"
publish_event "inventory.reserved" "$PAYLOAD_2"
sleep 1
dim "Publishing EXACT DUPLICATE event_id..."
publish_event "inventory.reserved" "$PAYLOAD_2"

# 3. Shipping Service
section "3. Shipping Service (Laravel) - payment.charged"
PAYLOAD_3="{\"event_id\":\"$EVENT_SHIPPING\", \"correlation_id\":\"$CORRELATION_ID\", \"payload\": {\"order_id\":\"$CORRELATION_ID\"}}"
dim "Publishing initial event_id: $EVENT_SHIPPING"
publish_event "payment.charged" "$PAYLOAD_3"
sleep 1
dim "Publishing EXACT DUPLICATE event_id..."
publish_event "payment.charged" "$PAYLOAD_3"

section "Waiting for processing"
info "Giving services $PROCESS_WAIT_SECONDS seconds to consume off RabbitMQ queues..."
sleep "$PROCESS_WAIT_SECONDS"

banner "Database Verification Results"

info "Checking Inventory DB (Should have exactly 1 record for event_id)..."
check_db_count "inventory_db" "$EVENT_INVENTORY"

echo ""
info "Checking Payment DB (Should have exactly 1 record for event_id)..."
check_db_count "payment_db" "$EVENT_PAYMENT"

echo ""
info "Checking Shipping DB (Should have exactly 1 record for event_id)..."
check_db_count "shipping_db" "$EVENT_SHIPPING"

echo ""
echo -e "  ${BOLD}Results:${RESET} Total: $TOTAL | Passed: ${GREEN}$PASSED${RESET} | Failed: ${RED}$FAILED${RESET} | Skipped: ${YELLOW}$SKIPPED${RESET}"
echo ""

if [ "$PASSED" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo -e "  🎉 ${GREEN}${BOLD}ALL TESTS PASSED! Idempotency is mathematically proven.${RESET}"
    exit 0
elif [ "$FAILED" -gt 0 ]; then
    echo -e "  💥 ${RED}${BOLD}SOME TESTS FAILED! We have a duplicate processing bug.${RESET}"
    exit 1
else
    echo -e "  ⚠️  ${YELLOW}${BOLD}TESTS SKIPPED! Start your services and run this again.${RESET}"
    exit 0
fi
