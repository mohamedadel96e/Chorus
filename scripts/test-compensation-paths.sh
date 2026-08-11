#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - E2E Compensation Paths Verification Script (Phase 5)
# ---------------------------------------------------------------------------
#  This script tests all 3 compensation paths (Inventory, Payment, Shipping)
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
NC='\033[0m'

PASS="${GREEN}PASS${NC}"
FAIL="${RED}FAIL${NC}"
INFO="${CYAN}INFO${NC}"

# ---------------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------------
ORDER_API="http://localhost:8081"
DB_USER="chorus"
DB_PASS="chorus"
ORDER_DB_PORT=5433
INVENTORY_DB_PORT=5434
PAYMENT_DB_PORT=5435
SHIPPING_DB_PORT=5436

export PGPASSWORD=$DB_PASS

# ---------------------------------------------------------------------------
#  Helper Functions
# ---------------------------------------------------------------------------
print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}============================================================${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}============================================================${NC}"
    echo ""
}

print_success() {
    echo -e "  [${PASS}] $1"
}

print_fail() {
    echo -e "  [${FAIL}] $1"
}

print_info() {
    echo -e "  [${INFO}] $1"
}

wait_for_status() {
    local order_id=$1
    local expected=$2
    local attempts=0
    local max=30
    print_info "Waiting for order $order_id to reach status: $expected..."
    while [ $attempts -lt $max ]; do
        local status
        status=$(docker exec chorus-postgres psql -U postgres -d order_db -t -c "SELECT status FROM orders WHERE id = '$order_id';" 2>/dev/null | xargs || true)
        
        if [ "$status" = "$expected" ]; then
            print_success "Order reached $expected status!"
            return 0
        fi
        sleep 1
        attempts=$((attempts+1))
    done
    print_fail "Timeout waiting for order to reach $expected status (last status: $status)"
    return 1
}

# ---------------------------------------------------------------------------
#  Main Execution
# ---------------------------------------------------------------------------

print_header "Path 1: Inventory Reservation Failure"
PRODUCT_FAIL_INV="prod-no-stock-$(date +%s)"
print_info "Setting product $PRODUCT_FAIL_INV to quantity 0"
docker exec chorus-postgres psql -U postgres -d inventory_db -c "INSERT INTO products (product_id, available_quantity) VALUES ('$PRODUCT_FAIL_INV', 0) ON CONFLICT (product_id) DO UPDATE SET available_quantity = 0;" > /dev/null

CUSTOMER_ID="cust-1"
RESPONSE=$(curl -s -X POST "${ORDER_API}/api/orders" \
  -H "Content-Type: application/json" \
  -d "{
    \"customerId\": \"$CUSTOMER_ID\",
    \"items\": [
      {
        \"productId\": \"$PRODUCT_FAIL_INV\",
        \"quantity\": 1,
        \"unitPriceCents\": 1000
      }
    ]
  }")
ORDER_ID=$(echo "$RESPONSE" | grep -o '"orderId":"[^"]*' | cut -d'"' -f4 || echo "")

wait_for_status "$ORDER_ID" "CANCELLED"

print_info "Verifying no reservation, no payment, no shipment..."
RES_COUNT=$(docker exec chorus-postgres psql -U postgres -d inventory_db -t -c "SELECT COUNT(*) FROM reservations WHERE order_id = '$ORDER_ID';" | xargs)
PAY_COUNT=$(docker exec chorus-postgres psql -U postgres -d payment_db -t -c "SELECT COUNT(*) FROM payments WHERE \"orderId\" = '$ORDER_ID';" | xargs)
SHIP_COUNT=$(docker exec chorus-postgres psql -U postgres -d shipping_db -t -c "SELECT COUNT(*) FROM shipments WHERE order_id = '$ORDER_ID';" | xargs)

if [ "$RES_COUNT" -eq 0 ] && [ "$PAY_COUNT" -eq 0 ] && [ "$SHIP_COUNT" -eq 0 ]; then
    print_success "Verified no downstream records created."
else
    print_fail "Found downstream records! Res: $RES_COUNT, Pay: $PAY_COUNT, Ship: $SHIP_COUNT"
fi

print_info "Verifying OrderCancelled outbox event exists..."
CANCEL_EVENT=$(docker exec chorus-postgres psql -U postgres -d order_db -t -c "SELECT COUNT(*) FROM outbox_events WHERE event_type = 'OrderCancelled' AND payload::text LIKE '%$ORDER_ID%';" | xargs)
if [ "$CANCEL_EVENT" -gt 0 ]; then
    print_success "OrderCancelled outbox event verified."
else
    print_fail "OrderCancelled outbox event missing."
fi

# ========================================================================
print_header "Path 2: Payment Failure (10% chance)"
PRODUCT_VALID="prod-valid-$(date +%s)"
docker exec chorus-postgres psql -U postgres -d inventory_db -c "INSERT INTO products (product_id, available_quantity) VALUES ('$PRODUCT_VALID', 1000) ON CONFLICT (product_id) DO UPDATE SET available_quantity = 1000;" > /dev/null

ORDER_ID_PAY_FAIL=""
echo -n "  [INFO] Polling for 10% random payment failure "
for i in {1..50}; do
    echo -n "."
    RESPONSE=$(curl -s -X POST "${ORDER_API}/api/orders" \
      -H "Content-Type: application/json" \
      -d "{
        \"customerId\": \"$CUSTOMER_ID\",
        \"items\": [
          {
            \"productId\": \"$PRODUCT_VALID\",
            \"quantity\": 1,
            \"unitPriceCents\": 1000
          }
        ]
      }")
    TEMP_ORDER_ID=$(echo "$RESPONSE" | grep -o '"orderId":"[^"]*' | cut -d'"' -f4 || echo "")
    
    PAY_STATUS=""
    for wait in {1..6}; do
        sleep 1
        PAY_STATUS=$(docker exec chorus-postgres psql -U postgres -d payment_db -t -c "SELECT status FROM payments WHERE \"orderId\" = '$TEMP_ORDER_ID' ORDER BY \"createdAt\" DESC LIMIT 1;" 2>/dev/null | xargs || true)
        if [ -n "$PAY_STATUS" ]; then break; fi
    done
    
    if [ "$PAY_STATUS" = "FAILED" ]; then
        echo ""
        ORDER_ID_PAY_FAIL=$TEMP_ORDER_ID
        print_success "Found payment.failed on attempt $i (Order: $ORDER_ID_PAY_FAIL)"
        break
    fi
done

if [ -z "$ORDER_ID_PAY_FAIL" ]; then
    print_fail "Could not trigger payment failure after 50 attempts."
else
    wait_for_status "$ORDER_ID_PAY_FAIL" "CANCELLED"
    
    RES_STATUS=$(docker exec chorus-postgres psql -U postgres -d inventory_db -t -c "SELECT status FROM reservations WHERE order_id = '$ORDER_ID_PAY_FAIL';" | xargs)
    if [ "$RES_STATUS" = "RELEASED" ]; then
        print_success "Reservation status is RELEASED."
    else
        print_fail "Reservation status is $RES_STATUS (expected RELEASED)."
    fi
    
    STOCK=$(docker exec chorus-postgres psql -U postgres -d inventory_db -t -c "SELECT available_quantity FROM products WHERE product_id = '$PRODUCT_VALID';" | xargs)
    EXPECTED_STOCK=$((1000 - (i - 1)))
    if [ "$STOCK" -eq "$EXPECTED_STOCK" ]; then
        print_success "Stock restored correctly to $EXPECTED_STOCK."
    else
        print_fail "Stock is $STOCK (expected $EXPECTED_STOCK)."
    fi
fi

# ========================================================================
print_header "Path 3: Shipment Failure (15% chance)"

ORDER_ID_SHIP_FAIL=""
echo -n "  [INFO] Polling for 15% random shipment failure "
for i in {1..50}; do
    echo -n "."
    RESPONSE=$(curl -s -X POST "${ORDER_API}/api/orders" \
      -H "Content-Type: application/json" \
      -d "{
        \"customerId\": \"$CUSTOMER_ID\",
        \"items\": [
          {
            \"productId\": \"$PRODUCT_VALID\",
            \"quantity\": 1,
            \"unitPriceCents\": 1000
          }
        ]
      }")
    TEMP_ORDER_ID=$(echo "$RESPONSE" | grep -o '"orderId":"[^"]*' | cut -d'"' -f4 || echo "")
    
    SHIP_STATUS=""
    for wait in {1..8}; do
        sleep 1
        SHIP_STATUS=$(docker exec chorus-postgres psql -U postgres -d shipping_db -t -c "SELECT status FROM shipments WHERE order_id = '$TEMP_ORDER_ID';" 2>/dev/null | xargs || true)
        if [ -n "$SHIP_STATUS" ]; then break; fi
    done
    
    if [ "$SHIP_STATUS" = "FAILED" ]; then
        echo ""
        ORDER_ID_SHIP_FAIL=$TEMP_ORDER_ID
        print_success "Found shipment.failed on attempt $i (Order: $ORDER_ID_SHIP_FAIL)"
        break
    fi
done

if [ -z "$ORDER_ID_SHIP_FAIL" ]; then
    print_fail "Could not trigger shipment failure after 50 attempts."
else
    wait_for_status "$ORDER_ID_SHIP_FAIL" "CANCELLED"
    
    PAY_STATUS=$(docker exec chorus-postgres psql -U postgres -d payment_db -t -c "SELECT status FROM payments WHERE \"orderId\" = '$ORDER_ID_SHIP_FAIL' ORDER BY \"createdAt\" DESC LIMIT 1;" | xargs)
    if [ "$PAY_STATUS" = "REFUNDED" ]; then
        print_success "Payment status is REFUNDED."
    else
        print_fail "Payment status is $PAY_STATUS (expected REFUNDED)."
    fi
    
    RES_STATUS=$(docker exec chorus-postgres psql -U postgres -d inventory_db -t -c "SELECT status FROM reservations WHERE order_id = '$ORDER_ID_SHIP_FAIL';" | xargs)
    if [ "$RES_STATUS" = "RELEASED" ]; then
        print_success "Reservation status is RELEASED."
    else
        print_fail "Reservation status is $RES_STATUS (expected RELEASED)."
    fi
fi

echo ""
print_header "All Tests Completed"
