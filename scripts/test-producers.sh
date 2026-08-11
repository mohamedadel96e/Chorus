#!/usr/bin/env bash
set -e

echo "============================================================"
echo "  Chorus End-to-End API Producer Verification"
echo "============================================================"
echo ""

echo "--- 1. Order Service (Port 8081) ---"
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId":"cust-123","currency":"USD","items":[{"productId":"prod-456","quantity":2,"unitPriceCents":500}]}' \
  | jq .

echo ""
echo "--- 2. Inventory Service (Port 8082) ---"
ORDER_ID=$(uuidgen)
curl -s -X POST http://localhost:8082/api/inventory/reserve \
  -H "Content-Type: application/json" \
  -d "{\"orderId\":\"$ORDER_ID\",\"items\":[{\"productId\":\"prod-456\",\"quantity\":1}]}" \
  | jq .

echo ""
echo "--- 3. Payment Service (Port 8083) ---"
curl -s -X POST http://localhost:8083/api/payment/charge \
  -H "Content-Type: application/json" \
  -d "{\"orderId\":\"$ORDER_ID\",\"amountCents\":1000,\"currency\":\"USD\"}" \
  | jq .

echo ""
echo "--- 4. Shipping Service (Port 8084) ---"
curl -s -X POST http://localhost:8084/api/shipping/schedule \
  -H "Content-Type: application/json" \
  -d "{\"orderId\":\"$ORDER_ID\",\"address\":\"123 Main St, Anytown, USA\"}" \
  | jq .

echo ""
echo "Verification complete!"
