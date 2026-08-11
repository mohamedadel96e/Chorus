#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - E2E Saga Compensations Verification Script (Phase 5)
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

# ---------------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------------
POSTGRES_CONTAINER="chorus-postgres"
POSTGRES_USER="postgres"
ORDER_API="http://localhost:8081"
PROCESS_WAIT_SECONDS=10
MAX_ATTEMPTS=20

echo -e "${BLUE}${BOLD}============================================================${RESET}"
echo -e "${BLUE}${BOLD}  Chorus E2E Saga Compensations Verification (Phase 5)${RESET}"
echo -e "${BLUE}${BOLD}============================================================${RESET}"
echo ""

echo -e "We will place up to $MAX_ATTEMPTS orders to trigger the 10% failure rates in Payment and Shipping services."
echo ""

payment_failed_seen=0
shipment_failed_seen=0

for i in $(seq 1 $MAX_ATTEMPTS); do
    CUSTOMER_ID="cust-$(uuidgen)"
    PRODUCT_ID="prod-12345"
    QUANTITY=1
    UNIT_PRICE_CENTS=10000

    echo -ne "Attempt $i/$MAX_ATTEMPTS: Submitting order... "

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
        echo -e "${RED}Failed to create order.${RESET}"
        continue
    fi

    echo -e "${GREEN}Created! ID: $ORDER_ID${RESET}"
    
    # Wait for processing
    sleep "$PROCESS_WAIT_SECONDS"

    # Check statuses
    set +eo pipefail
    ORDER_STATUS=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d order_db -t -c "SELECT status FROM orders WHERE id = '$ORDER_ID';" 2>/dev/null | xargs)
    PAYMENT_STATUS=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d payment_db -t -c "SELECT status FROM payments WHERE \"orderId\" = '$ORDER_ID' ORDER BY \"createdAt\" DESC LIMIT 1;" 2>/dev/null | xargs)
    SHIPPING_STATUS=$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d shipping_db -t -c "SELECT status FROM shipments WHERE order_id = '$ORDER_ID';" 2>/dev/null | xargs)
    set -eo pipefail
    
    echo -e "  -> Order: ${ORDER_STATUS}, Payment: ${PAYMENT_STATUS}, Shipping: ${SHIPPING_STATUS}"

    if [ "$PAYMENT_STATUS" == "FAILED" ] && [ "$ORDER_STATUS" == "CANCELLED" ]; then
        payment_failed_seen=1
        echo -e "  ${YELLOW}*** Captured Payment Failed Compensation! ***${RESET}"
    fi

    if [ "$SHIPPING_STATUS" == "FAILED" ] && [ "$PAYMENT_STATUS" == "REFUNDED" ] && [ "$ORDER_STATUS" == "CANCELLED" ]; then
        shipment_failed_seen=1
        echo -e "  ${YELLOW}*** Captured Shipment Failed Compensation! ***${RESET}"
    fi

    if [ $payment_failed_seen -eq 1 ] && [ $shipment_failed_seen -eq 1 ]; then
        echo ""
        echo -e "${GREEN}${BOLD}SUCCESS! Both compensation scenarios were successfully triggered and verified.${RESET}"
        chmod +x /mnt/d/Learning/Projects/Chorus/scripts/test-e2e-saga-compensations.sh
        exit 0
    fi
done

echo ""
echo -e "${RED}${BOLD}FAILED! Did not capture both compensation scenarios within $MAX_ATTEMPTS attempts.${RESET}"
echo -e "Payment Failed Seen: $payment_failed_seen"
echo -e "Shipment Failed Seen: $shipment_failed_seen"
exit 1
