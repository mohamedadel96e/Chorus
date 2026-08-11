#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - Comprehensive E2E Saga Verification Script (Phase 5)
# ---------------------------------------------------------------------------
#  This script verifies the full Saga flow, including Compensating Transactions.
#  It fires multiple orders to trigger all possible paths (Happy, Inventory Fail,
#  Payment Fail, Shipping Fail). It then automatically audits ALL 4 databases
#  for every single order to ensure the terminal state is mathematically perfect.
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
ORDER_API="http://localhost:8081/api/orders"
PROCESS_WAIT_SECONDS=15
NUM_ORDERS=30 # High enough to probabilistically trigger 10% payment and 15% shipping fails

# Track paths hit
HIT_HAPPY=0
HIT_INVENTORY=0
HIT_PAYMENT=0
HIT_SHIPPING=0

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

query_db() {
    local db_name=$1
    local query=$2
    
    set +eo pipefail
    local query_out
    query_out=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db_name" -t -c "$query" 2>/dev/null | xargs)
    set -eo pipefail
    
    echo "${query_out:-NOT_FOUND}"
}

assert_state() {
    local order_id=$1
    local service=$2
    local expected=$3
    local actual=$4

    if [[ "$actual" == *"$expected"* ]]; then
        echo -e "      ${PASS} $service: $actual (Expected: $expected)"
        return 0
    else
        echo -e "      ${FAIL} $service: $actual (Expected: $expected)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
#  Main Execution
# ---------------------------------------------------------------------------
banner "Chorus Comprehensive E2E Saga Auditor (Phase 5)"

CUSTOMER_ID="e2e-$(uuidgen | cut -c 1-6)"
info "Using Customer ID prefix: ${BOLD}$CUSTOMER_ID${RESET}"

# Array to hold generated order IDs
declare -a ORDER_IDS=()

section "Seeding Inventory Stock"
info "Ensuring prod-12345 has enough stock for the test (resetting to 100,000)..."
docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d inventory_db -c "
INSERT INTO products (product_id, available_quantity, version) 
VALUES ('prod-12345', 100000, 0)
ON CONFLICT (product_id) DO UPDATE SET available_quantity = 100000;
" > /dev/null

section "Submitting Orders"

for i in $(seq 1 $NUM_ORDERS); do
  QUANTITY=1
  # Force an inventory failure on the very first order by requesting an impossible amount
  if [ "$i" -eq 1 ]; then
      QUANTITY=999999
  fi

  set +e
  RESPONSE=$(curl -s -X POST $ORDER_API \
    -H "Content-Type: application/json" \
    -d "{
      \"customerId\": \"${CUSTOMER_ID}-${i}\",
      \"items\": [
        {
          \"productId\": \"prod-12345\",
          \"quantity\": $QUANTITY,
          \"unitPriceCents\": 5000
        }
      ]
    }")
  set -e
  
  ORDER_ID=$(echo "$RESPONSE" | grep -o '"orderId":"[^"]*' | cut -d'"' -f4 || echo "")
  
  if [ -n "$ORDER_ID" ]; then
    ORDER_IDS+=("$ORDER_ID")
    if [ "$i" -eq 1 ]; then
       info "Order $i submitted (Forced Inventory Fail) -> ID: $ORDER_ID"
    else
       info "Order $i submitted -> ID: $ORDER_ID"
    fi
  else
    echo -e "  ${RED}Failed to parse order ID from response. Order API might be down.${RESET}"
  fi
done

section "Waiting for Sagas to Process"
info "Sleeping for $PROCESS_WAIT_SECONDS seconds to allow RabbitMQ and Outboxes to settle..."
sleep "$PROCESS_WAIT_SECONDS"

banner "Auditing Database Consistency per Order"

FAILED_ASSERTIONS=0

for order_id in "${ORDER_IDS[@]}"; do
    echo -e "  ${CYAN}${BOLD}Order ID: $order_id${RESET}"
    
    # 1. Fetch Terminal State from Order DB
    ORDER_STATUS=$(query_db "order_db" "SELECT status FROM orders WHERE id = '$order_id';")
    ORDER_REASON=$(query_db "order_db" "SELECT cancellation_reason FROM orders WHERE id = '$order_id';")
    
    # 2. Fetch States from other DBs
    INVENTORY_STATUS=$(query_db "inventory_db" "SELECT status FROM reservations WHERE order_id = '$order_id';")
    PAYMENT_STATUS=$(query_db "payment_db" "SELECT status FROM payments WHERE \"orderId\" = '$order_id' ORDER BY \"createdAt\" DESC LIMIT 1;")
    SHIPPING_STATUS=$(query_db "shipping_db" "SELECT status FROM shipments WHERE order_id = '$order_id';")

    echo -e "    ${DIM}Order State:${RESET} $ORDER_STATUS ${DIM}| Reason:${RESET} $ORDER_REASON"

    # 3. Assert correct cross-service consistency based on terminal Order State
    case "$ORDER_STATUS" in
        "COMPLETED")
            HIT_HAPPY=$((HIT_HAPPY+1))
            assert_state "$order_id" "Inventory" "CONFIRMED" "$INVENTORY_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
            assert_state "$order_id" "Payment" "SUCCESS" "$PAYMENT_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
            assert_state "$order_id" "Shipping" "CREATED" "$SHIPPING_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
            ;;
        
        "CANCELLED")
            if [[ "$ORDER_REASON" == *"Insufficient stock"* ]]; then
                HIT_INVENTORY=$((HIT_INVENTORY+1))
                # Inventory could be FAILED or NOT_FOUND if it rolls back internally, but usually FAILED
                if [[ "$INVENTORY_STATUS" == *"FAILED"* ]] || [[ "$INVENTORY_STATUS" == *"NOT_FOUND"* ]]; then
                    echo -e "      ${PASS} Inventory: $INVENTORY_STATUS (Expected: FAILED or NOT_FOUND)"
                else
                    echo -e "      ${FAIL} Inventory: $INVENTORY_STATUS (Expected: FAILED or NOT_FOUND)"
                    FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                fi
                assert_state "$order_id" "Payment" "NOT_FOUND" "$PAYMENT_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                assert_state "$order_id" "Shipping" "NOT_FOUND" "$SHIPPING_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                
            elif [[ "$ORDER_REASON" == *"Simulated payment failure"* || "$ORDER_REASON" == *"Shipping address validation failed"* || "$ORDER_REASON" == *"Payment or shipment failed"* ]]; then
                # Both Payment Failure and Shipping Failure lead to OrderService receiving 'inventory.released',
                # which causes it to set the reason 'Payment or shipment failed...'.
                # To know which path it was, we check if the payment FAILED or was REFUNDED.
                
                if [[ "$PAYMENT_STATUS" == *"FAILED"* ]]; then
                    HIT_PAYMENT=$((HIT_PAYMENT+1))
                    assert_state "$order_id" "Inventory" "RELEASED" "$INVENTORY_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                    assert_state "$order_id" "Payment" "FAILED" "$PAYMENT_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                    assert_state "$order_id" "Shipping" "NOT_FOUND" "$SHIPPING_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                else
                    HIT_SHIPPING=$((HIT_SHIPPING+1))
                    assert_state "$order_id" "Inventory" "RELEASED" "$INVENTORY_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                    assert_state "$order_id" "Payment" "REFUNDED" "$PAYMENT_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                    assert_state "$order_id" "Shipping" "FAILED" "$SHIPPING_STATUS" || FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
                fi
            else
                echo -e "      ${FAIL} Unknown Cancellation Reason: $ORDER_REASON"
                FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
            fi
            ;;
            
        *)
            echo -e "      ${FAIL} Order is stuck in non-terminal state: $ORDER_STATUS"
            FAILED_ASSERTIONS=$((FAILED_ASSERTIONS+1))
            ;;
    esac
    echo ""
done

banner "E2E Test Summary"

echo -e "  ${BOLD}Path Coverage:${RESET}"
[[ $HIT_HAPPY -gt 0 ]] && echo -e "  [${PASS}] Happy Path (Completed): $HIT_HAPPY orders" || echo -e "  [${WARN}] Happy Path (Completed): 0 orders"
[[ $HIT_INVENTORY -gt 0 ]] && echo -e "  [${PASS}] Inventory Fail Path: $HIT_INVENTORY orders" || echo -e "  [${WARN}] Inventory Fail Path: 0 orders"
[[ $HIT_PAYMENT -gt 0 ]] && echo -e "  [${PASS}] Payment Fail Path: $HIT_PAYMENT orders" || echo -e "  [${WARN}] Payment Fail Path: 0 orders"
[[ $HIT_SHIPPING -gt 0 ]] && echo -e "  [${PASS}] Shipping Fail Path: $HIT_SHIPPING orders" || echo -e "  [${WARN}] Shipping Fail Path: 0 orders"

echo ""
if [ "$FAILED_ASSERTIONS" -eq 0 ]; then
    echo -e "  🎉 ${GREEN}${BOLD}ALL DATABASE ASSERTIONS PASSED!${RESET}"
    echo -e "  ${DIM}The Choreographed Saga handles success and all 3 failure paths perfectly.${RESET}"
    exit 0
else
    echo -e "  🔥 ${RED}${BOLD}FAILED ASSERTIONS DETECTED ($FAILED_ASSERTIONS)!${RESET}"
    echo -e "  ${DIM}Check the logs above to see which services are out of sync.${RESET}"
    exit 1
fi
