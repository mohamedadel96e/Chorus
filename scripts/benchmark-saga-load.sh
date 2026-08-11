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

# Default values
CONCURRENCY=10
TOTAL=50
RUN_ALL=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --concurrency) CONCURRENCY="$2"; shift ;;
        --total) TOTAL="$2"; shift ;;
        --run-all) RUN_ALL=1 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

echo -e "${MAGENTA}======================================================${NC}"
echo -e "${MAGENTA}        Chorus Saga Load Benchmark Tool               ${NC}"
echo -e "${MAGENTA}======================================================${NC}"

# Database access helper
query_db() {
    local db=$1
    local query=$2
    docker exec chorus-postgres psql -U postgres -d "$db" -t -c "$query" | xargs
}

setup_databases() {
    echo -e "\n${BLUE}➤ Resetting databases...${NC}"
    
    # Order DB
    query_db "order_db" "TRUNCATE orders, order_items, outbox_events, processed_events, event_trace CASCADE;"
    
    # Inventory DB
    query_db "inventory_db" "TRUNCATE reservations, reservation_items, outbox_events, processed_events CASCADE;"
    query_db "inventory_db" "INSERT INTO products (product_id, available_quantity, version) VALUES ('prod-bench', 10000, 0) ON CONFLICT (product_id) DO UPDATE SET available_quantity = 10000, version = 0;"
    
    # Payment DB
    query_db "payment_db" "TRUNCATE payments, outbox_events, processed_events CASCADE;"
    
    # Shipping DB
    query_db "shipping_db" "TRUNCATE shipments, outbox_events, processed_events CASCADE;"
    
    echo -e "${GREEN}✔ Databases reset successfully.${NC}"
}

run_round() {
    local c=$1
    local t=$2
    echo -e "\n${CYAN}======================================================${NC}"
    echo -e "${CYAN}▶ Running Round: Concurrency=$c, Total=$t${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    setup_databases
    
    echo -e "${BLUE}➤ Firing $t orders with concurrency $c...${NC}"
    
    local start_time=$(date +%s.%N)
    
    # Fire requests
    # We use xargs to handle concurrency robustly
    seq 1 "$t" | xargs -P "$c" -I {} bash -c '
        payload="{\"customerId\":\"cust-bench-{}\",\"items\":[{\"productId\":\"prod-bench\",\"quantity\":1,\"unitPriceCents\":1000}]}"
        curl -s -m 10 -X POST -H "Content-Type: application/json" -d "$payload" http://localhost:8081/api/orders > /dev/null
        # Print a dot for every 10th request (approximation for progress)
        if (( {} % 10 == 0 )); then echo -n "."; fi
    '
    
    echo -e "\n${GREEN}✔ All $t order requests sent.${NC}"
    
    # Wait for completion
    echo -e "${BLUE}➤ Waiting for orders to reach terminal state...${NC}"
    local poll_interval=2
    local max_wait=120
    local elapsed=0
    local done=0
    
    while (( elapsed < max_wait )); do
        local completed=$(query_db "order_db" "SELECT COUNT(*) FROM orders WHERE status = 'COMPLETED';")
        local cancelled=$(query_db "order_db" "SELECT COUNT(*) FROM orders WHERE status = 'CANCELLED';")
        local total_done=$((completed + cancelled))
        
        echo -ne "\r${YELLOW}Waiting... [$elapsed s] Completed: $completed, Cancelled: $cancelled, Total Done: $total_done / $t${NC}"
        
        if (( total_done >= t )); then
            done=1
            break
        fi
        
        sleep $poll_interval
        ((elapsed += poll_interval))
    done
    
    echo -e ""
    
    local end_time=$(date +%s.%N)
    local wall_time=$(echo "$end_time - $start_time" | bc -l)
    
    local completed=$(query_db "order_db" "SELECT COUNT(*) FROM orders WHERE status = 'COMPLETED';")
    local cancelled=$(query_db "order_db" "SELECT COUNT(*) FROM orders WHERE status = 'CANCELLED';")
    local stuck=$((t - completed - cancelled))
    
    local completion_rate=$(echo "scale=2; ($completed + $cancelled) * 100 / $t" | bc)
    local throughput=$(echo "scale=2; $t / $wall_time" | bc)
    
    # Latency calc using order_db event_trace (requires specific setup, mocking some values if table missing)
    # Getting p50, p95, p99
    # This query extracts the lifecycle time of an order (max trace time - order creation time)
    local latency_query="
        WITH order_times AS (
            SELECT 
                o.id as order_id, 
                EXTRACT(EPOCH FROM (MAX(e.occurred_at) - o.created_at)) as duration
            FROM orders o
            JOIN event_trace e ON CAST(o.id AS text) = CAST(e.correlation_id AS text)
            WHERE o.status IN ('COMPLETED', 'CANCELLED')
            GROUP BY o.id, o.created_at
        )
        SELECT 
            COALESCE(percentile_cont(0.50) WITHIN GROUP (ORDER BY duration), 0),
            COALESCE(percentile_cont(0.95) WITHIN GROUP (ORDER BY duration), 0),
            COALESCE(percentile_cont(0.99) WITHIN GROUP (ORDER BY duration), 0)
        FROM order_times;
    "
    local latencies=$(docker exec chorus-postgres psql -U postgres -d order_db -t -c "$latency_query" 2>/dev/null | xargs || echo "0 0 0")
    local p50=$(echo $latencies | awk -F'|' '{print $1}')
    local p95=$(echo $latencies | awk -F'|' '{print $2}')
    local p99=$(echo $latencies | awk -F'|' '{print $3}')
    
    echo -e "\n${MAGENTA}--- Results ---${NC}"
    echo -e "Total orders created: ${CYAN}$t${NC}"
    echo -e "Completed: ${GREEN}$completed${NC} | Cancelled: ${RED}$cancelled${NC} | Stuck: ${YELLOW}$stuck${NC}"
    echo -e "Completion Rate: ${CYAN}${completion_rate}%${NC}"
    printf "Total Wall-Clock Time: ${CYAN}%.2f s${NC}\n" $wall_time
    echo -e "Throughput: ${CYAN}${throughput} orders/sec${NC}"
    echo -e "Latency (s): p50=${CYAN}${p50}${NC} | p95=${CYAN}${p95}${NC} | p99=${CYAN}${p99}${NC}"
    
    # Save to temp file for final summary
    printf "%-5s | %-6s | %-6s | %-6s | %-5s | %-8s | %-10s | %-5s | %-5s | %-5s\n" "$c" "$t" "$completed" "$cancelled" "$stuck" "${completion_rate}%" "$(printf "%.2f" $throughput)" "${p50:0:5}" "${p95:0:5}" "${p99:0:5}" >> /tmp/chorus_bench_summary.txt
}

# Clear summary file
echo "C/Cyc | Total  | Comp.  | Canc.  | Stuck | Rate     | Thrp(o/s)  | p50   | p95   | p99  " > /tmp/chorus_bench_summary.txt
echo "------|--------|--------|--------|-------|----------|------------|-------|-------|------" >> /tmp/chorus_bench_summary.txt

if (( RUN_ALL == 1 )); then
    ROUNDS=(10 25 50 100 250 500 1000)
    for c in "${ROUNDS[@]}"; do
        t=$((c * 5))
        run_round $c $t
    done
else
    run_round $CONCURRENCY $TOTAL
fi

echo -e "\n${MAGENTA}==========================================================================================${NC}"
echo -e "${MAGENTA}                                FINAL SUMMARY                                             ${NC}"
echo -e "${MAGENTA}==========================================================================================${NC}"
cat /tmp/chorus_bench_summary.txt
echo -e "${MAGENTA}==========================================================================================${NC}"
rm /tmp/chorus_bench_summary.txt
