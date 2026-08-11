#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - Chaos Tester (Phase 9)
# ---------------------------------------------------------------------------
#  This script proves our Choreographed Saga is immune to hard crashes.
#  It injects a "chaos" product that tells the Payment Service to crash
#  itself *after* committing to its DB but *before* acknowledging the 
#  message to RabbitMQ. We then restart it and verify no data was duplicated
#  and the saga completes successfully.
# ---------------------------------------------------------------------------

set -euo pipefail

# Ensure we are in the project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "$SCRIPT_DIR")" = "scripts" ]; then
    cd "$SCRIPT_DIR/.."
else
    cd "$SCRIPT_DIR"
fi

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
ARROW="${CYAN}>>>${RESET}"

POSTGRES_CONTAINER="chorus-postgres"
POSTGRES_USER="postgres"
ORDER_API="http://localhost:8081"

banner() {
    echo ""
    echo -e "${BLUE}${BOLD}======================================================================${RESET}"
    echo -e "${BLUE}${BOLD}  Chorus Chaos Tester${RESET}"
    echo -e "${BLUE}${BOLD}======================================================================${RESET}"
    echo ""
}

info() {
    echo -e "  ${ARROW} $1"
}

dim() {
    echo -e "  ${DIM}$1${RESET}"
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

banner

if [ ! -f "payment.pid" ]; then
    echo -e "  ${RED}payment.pid not found! Are the services running locally (via start-all.sh)?${RESET}"
    exit 1
fi

CUSTOMER_ID="cust-chaos-$(uuidgen)"
PRODUCT_ID="prod-456"
ORDER_ID=""

info "1. Submitting 'poison' order that will trigger Payment Service crash..."
info "   Product ID: ${BOLD}$PRODUCT_ID${RESET}"

set +e
RESPONSE=$(curl -s -X POST "${ORDER_API}/api/orders" \
  -H "Content-Type: application/json" \
  -d "{
    \"customerId\": \"$CUSTOMER_ID\",
    \"items\": [
      {
        \"productId\": \"$PRODUCT_ID\",
        \"quantity\": 1,
        \"unitPriceCents\": 5000
      }
    ]
  }")
set -e

ORDER_ID=$(echo "$RESPONSE" | grep -o '"orderId":"[^"]*' | cut -d'"' -f4 || echo "")

if [ -z "$ORDER_ID" ]; then
    echo -e "  ${RED}Failed to create order.${RESET}"
    exit 1
fi
info "   Order Created! ID: ${BOLD}$ORDER_ID${RESET}"

echo ""
info "2. Waiting 4 seconds for Payment Service to process and intentionally crash..."
sleep 4

# Check if process is still alive
PAYMENT_PID=$(cat payment.pid)
if ps -p $PAYMENT_PID > /dev/null; then
    echo -e "  ${FAIL} Payment Service (PID $PAYMENT_PID) is STILL RUNNING! Chaos hook failed."
    exit 1
else
    echo -e "  ${PASS} Payment Service crashed successfully as expected!"
fi

echo ""
info "3. Restarting Payment Service to test Idempotency recovery..."
(cd payment-service && PORT=8083 npm run start > ../payment-service.log 2>&1 & echo $! > payment.pid)
NEW_PID=$(cat payment.pid)
info "   Service restarted with new PID: $NEW_PID"

echo ""
info "4. Waiting 10 seconds for service to boot, consume un-acked message, and finish saga..."
sleep 10

echo ""
info "5. Verifying Database States..."

# Check Order State
ORDER_STATE=$(query_db "order_db" "SELECT status FROM orders WHERE id = '$ORDER_ID';")
if [ "$ORDER_STATE" == "COMPLETED" ]; then
    echo -e "  ${PASS} Order reached terminal state: ${BOLD}COMPLETED${RESET}"
else
    echo -e "  ${FAIL} Order state is: ${BOLD}$ORDER_STATE${RESET} (Expected: COMPLETED)"
    exit 1
fi

# Check Payment Count
PAYMENT_COUNT=$(query_db "payment_db" "SELECT COUNT(*) FROM payments WHERE \"orderId\" = '$ORDER_ID';")
if [ "$PAYMENT_COUNT" == "1" ]; then
    echo -e "  ${PASS} Exactly ${BOLD}ONE${RESET} payment record exists! (Idempotency prevented duplicate charges)"
else
    echo -e "  ${FAIL} Found ${BOLD}$PAYMENT_COUNT${RESET} payment records! Idempotency failed!"
    exit 1
fi

echo ""
echo -e "  🎉 ${GREEN}${BOLD}CHAOS TEST PASSED!${RESET}"
echo -e "  ${DIM}The saga is resilient to hard crashes without corrupting or duplicating data.${RESET}"
echo ""
