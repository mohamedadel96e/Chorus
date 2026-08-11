#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - Race Condition Simulator (Phase 6)
# ---------------------------------------------------------------------------
#  This script simulates out-of-order event delivery inherent to choreographed
#  sagas. It tests if the OrderService gracefully rejects a delayed 
#  'payment.charged' event after it has already processed 'shipment.failed'.
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

PASS="${GREEN}✔ PASS${RESET}"
FAIL="${RED}✘ FAIL${RESET}"
WARN="${YELLOW}⚠ WARN${RESET}"
ARROW="${CYAN}>>>${RESET}"

# ---------------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------------
POSTGRES_CONTAINER="chorus-postgres"
POSTGRES_USER="postgres"
ORDER_DB="order_db"

# ---------------------------------------------------------------------------
#  Helper Functions
# ---------------------------------------------------------------------------
banner() {
    echo ""
    echo -e "${BLUE}${BOLD}======================================================================${RESET}"
    echo -e "${BLUE}${BOLD}  $1${RESET}"
    echo -e "${BLUE}${BOLD}======================================================================${RESET}"
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

publish_event() {
    local routing_key=$1
    local event_id=$2
    local order_id=$3

    local msg_body="{\"event_id\":\"$event_id\",\"correlation_id\":\"$order_id\",\"payload\":{\"order_id\":\"$order_id\"}}"
    local escaped_msg_body=$(echo "$msg_body" | sed 's/"/\\"/g')

    curl -s -u guest:guest -H "content-type:application/json" \
      -X POST http://localhost:15672/api/exchanges/%2F/chorus.events/publish \
      -d "{
        \"properties\": {\"delivery_mode\": 2, \"content_type\": \"application/json\"},
        \"routing_key\": \"$routing_key\",
        \"payload\": \"$escaped_msg_body\",
        \"payload_encoding\": \"string\"
      }" > /dev/null
}

query_db() {
    local db_name=$1
    local query=$2
    
    set +eo pipefail
    local query_out
    query_out=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db_name" -t -c "$query" 2>/dev/null | xargs)
    set -eo pipefail
    
    echo "${query_out:-NOT_FOUND}"
}

# ---------------------------------------------------------------------------
#  Main Execution
# ---------------------------------------------------------------------------
banner "Chorus Race Condition Simulator (Phase 6)"

ORDER_ID=$(uuidgen)
EVENT_ID_1=$(uuidgen)
EVENT_ID_2=$(uuidgen)

section "1. Creating synthetic order (bypassing saga)"
info "Injecting an isolated PENDING order directly into the database to avoid race conditions with actual services."
docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$ORDER_DB" -c "
INSERT INTO orders (id, customer_id, total_amount_cents, currency, status, created_at)
VALUES ('$ORDER_ID', 'race-condition-tester', 5000, 'USD', 'PENDING', NOW());
" > /dev/null

STATE0=$(query_db "$ORDER_DB" "SELECT status FROM orders WHERE id = '$ORDER_ID';")
info "Order ID: ${BOLD}$ORDER_ID${RESET} ${DIM}(State: $STATE0)${RESET}"

sleep 1

section "2. Simulating Out-of-Order Delivery"
info "Injecting [${YELLOW}shipment.failed${RESET}] event out of order..."
publish_event "shipment.failed" "$EVENT_ID_1" "$ORDER_ID"

sleep 1

STATE1=$(query_db "$ORDER_DB" "SELECT status FROM orders WHERE id = '$ORDER_ID';")
if [ "$STATE1" == "SHIPMENT_FAILED" ]; then
    echo -e "  ${PASS} Order transitioned to: ${BOLD}$STATE1${RESET}"
else
    echo -e "  ${FAIL} Order state is: ${BOLD}$STATE1${RESET} (Expected: SHIPMENT_FAILED)"
    exit 1
fi

sleep 1

info "Injecting [${YELLOW}payment.charged${RESET}] event (arriving LATE)..."
publish_event "payment.charged" "$EVENT_ID_2" "$ORDER_ID"

sleep 1

STATE2=$(query_db "$ORDER_DB" "SELECT status FROM orders WHERE id = '$ORDER_ID';")
info "Checking Order state after late [${YELLOW}payment.charged${RESET}]..."

echo ""
if [ "$STATE2" == "CONFIRMED" ]; then
  echo -e "  ${FAIL} State regressed from SHIPMENT_FAILED to ${BOLD}CONFIRMED${RESET}!"
  dim "This is a race condition vulnerability. The late payment event overrode the failure."
  echo ""
  exit 1
elif [ "$STATE2" == "SHIPMENT_FAILED" ]; then
  echo -e "  ${PASS} State safely remained in ${BOLD}SHIPMENT_FAILED${RESET}!"
  dim "The Order Service's Strict State Machine gracefully ignored the late payment event."
  echo ""
  
  banner "E2E Test Summary"
  echo -e "  🎉 ${GREEN}${BOLD}RACE CONDITION MITIGATED!${RESET}"
  echo -e "  ${DIM}The Choreographed Saga is immune to out-of-order delivery across these boundaries.${RESET}"
  exit 0
else
  echo -e "  ${FAIL} Unknown State: $STATE2"
  exit 1
fi
