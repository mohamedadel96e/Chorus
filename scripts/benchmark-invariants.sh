#!/bin/bash
set -euo pipefail

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${MAGENTA}======================================================${NC}"
echo -e "${MAGENTA}        Chorus Invariants Checker Tool                ${NC}"
echo -e "${MAGENTA}======================================================${NC}"

# Database access helper
query_db() {
    local db=$1
    local query=$2
    docker exec chorus-postgres psql -U postgres -d "$db" -t -c "$query" | xargs
}

TOTAL_CHECKS=0
PASSED=0
FAILED=0

check_invariant() {
    local name=$1
    local expected=$2
    local actual=$3
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo -e "[ ${GREEN}PASS${NC} ] $name (Actual: $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "[ ${RED}FAIL${NC} ] $name (Expected: $expected, Actual: $actual)"
        FAILED=$((FAILED + 1))
    fi
}

echo -e "\n${BLUE}➤ Checking Orders Invariants...${NC}"
# No stuck orders
stuck_orders=$(query_db "order_db" "SELECT COUNT(*) FROM orders WHERE status NOT IN ('COMPLETED', 'CANCELLED');")
check_invariant "No stuck orders" "0" "$stuck_orders"

echo -e "\n${BLUE}➤ Checking Payments Invariants...${NC}"
# No duplicate payments
dup_payments=$(query_db "payment_db" 'SELECT COUNT(*) FROM (SELECT "orderId" FROM payments GROUP BY "orderId" HAVING COUNT(*) > 1) t;')
check_invariant "No duplicate payments" "0" "$dup_payments"

echo -e "\n${BLUE}➤ Checking Inventory Invariants...${NC}"
# Stock conservation: initial stock (10000) == current stock + SUM(confirmed reservation quantities)
# Wait, let's get current stock of 'prod-bench'
current_stock=$(query_db "inventory_db" "SELECT available_quantity FROM products WHERE product_id = 'prod-bench';")
# And reserved quantity
reserved_qty=$(query_db "inventory_db" "SELECT COALESCE(SUM(ri.quantity), 0) FROM reservation_items ri JOIN reservations r ON ri.reservation_id = r.id WHERE r.status = 'CONFIRMED' AND ri.product_id = 'prod-bench';")
total_stock=$((current_stock + reserved_qty))
check_invariant "Stock conservation (Initial: 10000)" "10000" "$total_stock"

# Orphaned reservations: Every CONFIRMED reservation has a matching COMPLETED order
# We need to cross-check across DBs.
    # 1. Get confirmed reservation order_ids
    query_db "inventory_db" "SELECT order_id FROM reservations WHERE status = 'CONFIRMED';" | tr ' ' '\n' | sort | uniq > /tmp/inv_orders.txt
    
    if [ ! -s /tmp/inv_orders.txt ]; then
        orphaned_count=0
    else
        # 2. Get completed orders
        query_db "order_db" "SELECT id FROM orders WHERE status = 'COMPLETED';" | tr ' ' '\n' | sort | uniq > /tmp/comp_orders.txt
        
        # 3. Find confirmed reservations that don't have a completed order
        orphaned_count=$(comm -23 /tmp/inv_orders.txt /tmp/comp_orders.txt | wc -l | tr -d ' ')
    fi
check_invariant "No orphaned reservations" "0" "$orphaned_count"

echo -e "\n${BLUE}➤ Checking Outbox Invariants...${NC}"
# Outbox fully drained across all DBs
outbox_order=$(query_db "order_db" "SELECT COUNT(*) FROM outbox_events WHERE status = 'PENDING';")
outbox_inv=$(query_db "inventory_db" "SELECT COUNT(*) FROM outbox_events WHERE status = 'PENDING';")
outbox_pay=$(query_db "payment_db" "SELECT COUNT(*) FROM outbox_events WHERE status = 'PENDING';")
outbox_ship=$(query_db "shipping_db" "SELECT COUNT(*) FROM outbox_events WHERE status = 'PENDING';")

total_pending_outbox=$((outbox_order + outbox_inv + outbox_pay + outbox_ship))
check_invariant "Outbox fully drained across all DBs" "0" "$total_pending_outbox"

echo -e "\n${MAGENTA}======================================================${NC}"
echo -e "${MAGENTA}                 SUMMARY                              ${NC}"
echo -e "${MAGENTA}======================================================${NC}"
echo -e "Total Checks: $TOTAL_CHECKS"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"

if (( FAILED > 0 )); then
    echo -e "\n${RED}✘ Invariants check failed!${NC}"
    exit 1
else
    echo -e "\n${GREEN}✔ All invariants passed successfully!${NC}"
    exit 0
fi
