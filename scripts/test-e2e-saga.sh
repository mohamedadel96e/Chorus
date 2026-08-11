#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - E2E Saga Verification Script (Phase 4)
# ---------------------------------------------------------------------------
#  This script verifies the full Saga flow by hitting the Order API and
#  observing the state transitions across all microservices' databases.
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
ORDER_API="http://localhost:8081"
PROCESS_WAIT_SECONDS=8

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
    local status="$1"
    local description="$2"
    if [ "$status" = "pass" ]; then
        echo -e "  [${PASS}] $description"
    elif [ "$status" = "fail" ]; then
        echo -e "  [${FAIL}] $description"
    else
        echo -e "  [${SKIP}] $description"
    fi
}

check_db_status() {
    local db_name=$1
    local query=$2
    
    set +eo pipefail
    local query_out
    query_out=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db_name" -t -c "$query" 2>/dev/null)
    local query_code=$?
    set -eo pipefail
    
    if [ $query_code -ne 0 ]; then
        result "fail" "Could not connect to database $db_name (Docker exec failed)"
        return
    fi
    
    local status
    status=$(echo "$query_out" | xargs)
    status=${status:-"NOT_FOUND"}
    
    if [ "$status" = "NOT_FOUND" ]; then
        result "skip" "$db_name record status: [${status}]"
    elif [[ "$status" =~ FAILED|CANCELLED|REFUNDED|RELEASED ]]; then
        result "fail" "$db_name record status: [${status}] (Saga compensated/failed)"
    else
        result "pass" "$db_name record status: [${status}]"
    fi
}

# ---------------------------------------------------------------------------
#  Main Execution
# ---------------------------------------------------------------------------
banner "Chorus E2E Saga Verification (Phase 4)"

CUSTOMER_ID="cust-$(uuidgen)"
PRODUCT_ID="prod-12345"
QUANTITY=1
UNIT_PRICE_CENTS=10000

info "Using Customer ID: ${BOLD}$CUSTOMER_ID${RESET}"
info "Using Product ID:  ${BOLD}$PRODUCT_ID${RESET}"

section "Submitting Order to Order Service API"

# Use set +e around curl so we can gracefully handle failure
set +e
RESPONSE=$(curl -s -X POST "${ORDER_API}/api/orders" \
  -H "Content-Type: application/json" \
  -d "{
    \"customerId\": \"$CUSTOMER_ID\",
    \"items\": [
      {
        \"productId\": \"$PRODUCT_ID\",
        \"quantity\": $QUANTITY,
        \"unitPriceCents\": $UNIT_PRICE_CENTS
      }
    ]
  }")
set -e

ORDER_ID=$(echo "$RESPONSE" | grep -o '"orderId":"[^"]*' | cut -d'"' -f4 || echo "")

if [ -z "$ORDER_ID" ]; then
    echo -e "  ⚠️  ${RED}Failed to create order. Is the Order Service running?${RESET}"
    dim "Response: $RESPONSE"
    exit 1
fi

info "Order Created! Order ID: ${BOLD}$ORDER_ID${RESET}"

section "Waiting for processing"
info "Giving services $PROCESS_WAIT_SECONDS seconds for the full Saga to complete..."
sleep "$PROCESS_WAIT_SECONDS"

banner "Database Verification Results"

info "Checking Order DB (Should be COMPLETED or CANCELLED)..."
check_db_status "order_db" "SELECT status FROM orders WHERE id = '$ORDER_ID';"

echo ""
info "Checking Inventory DB (Reservation)..."
check_db_status "inventory_db" "SELECT status FROM reservations WHERE order_id = '$ORDER_ID';"

echo ""
info "Checking Payment DB (PaymentRecord)..."
check_db_status "payment_db" "SELECT status FROM payments WHERE \"orderId\" = '$ORDER_ID' ORDER BY \"createdAt\" DESC LIMIT 1;"

echo ""
info "Checking Shipping DB (Shipment)..."
check_db_status "shipping_db" "SELECT status FROM shipments WHERE order_id = '$ORDER_ID';"

echo ""
echo -e "  🎉 ${GREEN}${BOLD}E2E Test Completed!${RESET} Check above for outcomes."
echo ""
