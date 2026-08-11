#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - Outbox Load Test
# ---------------------------------------------------------------------------
#  This script simulates a high-throughput burst of orders flowing through
#  the Chorus system. It bulk-inserts a configurable number of PENDING
#  outbox events into each service's database, then monitors the relay
#  workers as they drain the backlog and publish to RabbitMQ.
#
#  The goal is to observe how the polling relays behave under pressure:
#    - How fast does each service drain its outbox?
#    - Does the relay batch size become a bottleneck?
#    - Does RabbitMQ receive all expected messages?
#
#  Prerequisites:
#    - Docker containers (chorus-postgres, chorus-rabbitmq) must be running.
#    - All service relay workers must be running.
#    - jq must be installed.
#
#  Usage:
#    chmod +x scripts/load-test-outbox.sh
#    ./scripts/load-test-outbox.sh              # default: 500 events/service
#    ./scripts/load-test-outbox.sh 1000          # 1000 events/service
#    ./scripts/load-test-outbox.sh 2000 60       # 2000 events, 60s timeout
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
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

BLOCK_FULL="█"
BLOCK_LIGHT="░"
ARROW="${CYAN}>>>${RESET}"
SPARK="${YELLOW}⚡${RESET}"
CLOCK="${CYAN}⏱${RESET}"
CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"

# ---------------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------------
EVENTS_PER_SERVICE="${1:-500}"
DRAIN_TIMEOUT_SECONDS="${2:-120}"
POLL_INTERVAL=2

POSTGRES_CONTAINER="chorus-postgres"
POSTGRES_USER="postgres"
RABBITMQ_HOST="localhost"
RABBITMQ_PORT="15672"
RABBITMQ_USER="guest"
RABBITMQ_PASS="guest"
EXCHANGE_NAME="chorus.events"

TOTAL_EVENTS=$((EVENTS_PER_SERVICE * 4))

# Service definitions: db_name, event_type, routing_key, payload_template
declare -A SERVICE_DB=(
    [order]="order_db"
    [inventory]="inventory_db"
    [payment]="payment_db"
    [shipping]="shipping_db"
)
declare -A SERVICE_EVENT_TYPE=(
    [order]="OrderCreatedEvent"
    [inventory]="InventoryReservedEvent"
    [payment]="PaymentProcessedEvent"
    [shipping]="ShipmentScheduledEvent"
)
declare -A SERVICE_ROUTING_KEY=(
    [order]="order.created"
    [inventory]="inventory.reserved"
    [payment]="payment.processed"
    [shipping]="shipping.scheduled"
)
declare -A SERVICE_COLOR=(
    [order]="$BLUE"
    [inventory]="$MAGENTA"
    [payment]="$YELLOW"
    [shipping]="$CYAN"
)
declare -A SERVICE_LABEL=(
    [order]="Order     (Spring)"
    [inventory]="Inventory (Spring)"
    [payment]="Payment   (NestJS)"
    [shipping]="Shipping  (Laravel)"
)

SERVICES=(order inventory payment shipping)

# ---------------------------------------------------------------------------
#  Helper Functions
# ---------------------------------------------------------------------------

banner() {
    local width=64
    local text="$1"
    local pad=$(( (width - ${#text} - 2) / 2 ))
    echo ""
    echo -e "${BLUE}${BOLD}$(printf '=%.0s' $(seq 1 $width))${RESET}"
    echo -e "${BLUE}${BOLD}$(printf ' %.0s' $(seq 1 $pad)) $text${RESET}"
    echo -e "${BLUE}${BOLD}$(printf '=%.0s' $(seq 1 $width))${RESET}"
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

timestamp() {
    date '+%H:%M:%S'
}

psql_exec() {
    local db="$1"
    local sql="$2"
    docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$db" -t -A -c "$sql" 2>/dev/null
}

get_pending_count() {
    local db="$1"
    psql_exec "$db" "SELECT count(*) FROM outbox_events WHERE status = 'PENDING';"
}

get_published_count() {
    local db="$1"
    psql_exec "$db" "SELECT count(*) FROM outbox_events WHERE status = 'PUBLISHED';"
}

get_exchange_publish_in() {
    curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASS" \
        "http://$RABBITMQ_HOST:$RABBITMQ_PORT/api/exchanges/%2F/$EXCHANGE_NAME" 2>/dev/null \
        | jq -r '.message_stats.publish_in // 0' 2>/dev/null || echo "0"
}

progress_bar() {
    local current="$1"
    local total="$2"
    local width=30
    local color="$3"

    if [ "$total" -eq 0 ]; then
        local filled=0
        local pct=0
    else
        local pct=$(( current * 100 / total ))
        local filled=$(( current * width / total ))
    fi
    local empty=$(( width - filled ))

    local bar="${color}"
    for ((i=0; i<filled; i++)); do bar+="$BLOCK_FULL"; done
    bar+="${DIM}"
    for ((i=0; i<empty; i++)); do bar+="$BLOCK_LIGHT"; done
    bar+="${RESET}"

    printf "%s %3d%%" "$bar" "$pct"
}

generate_payload() {
    local service="$1"
    local index="$2"
    local amount=$(( (RANDOM % 50000) + 500 ))

    case "$service" in
        order)
            echo "{\"orderId\": $index, \"customerId\": $((RANDOM % 1000 + 1)), \"totalCents\": $amount, \"items\": [{\"sku\": \"ITEM-$(printf '%04d' $((RANDOM % 500)))\", \"qty\": $((RANDOM % 5 + 1))}]}"
            ;;
        inventory)
            echo "{\"orderId\": $index, \"sku\": \"ITEM-$(printf '%04d' $((RANDOM % 500)))\", \"quantity\": $((RANDOM % 10 + 1)), \"warehouseId\": \"WH-$(printf '%02d' $((RANDOM % 5 + 1)))\"}"
            ;;
        payment)
            local methods=("card" "paypal" "apple_pay" "bank_transfer")
            local method="${methods[$((RANDOM % 4))]}"
            echo "{\"orderId\": $index, \"amountCents\": $amount, \"method\": \"$method\", \"currency\": \"USD\"}"
            ;;
        shipping)
            echo "{\"orderId\": $index, \"shippingMethod\": \"standard\", \"costCents\": $((amount / 10)), \"addressId\": 100}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
#  Pre-flight Checks
# ---------------------------------------------------------------------------

banner "Chorus Outbox Load Test"

echo -e "  ${BOLD}Date:${RESET}              $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  ${BOLD}Events/Service:${RESET}    ${WHITE}${EVENTS_PER_SERVICE}${RESET}"
echo -e "  ${BOLD}Total Events:${RESET}      ${WHITE}${TOTAL_EVENTS}${RESET}"
echo -e "  ${BOLD}Drain Timeout:${RESET}     ${DRAIN_TIMEOUT_SECONDS}s"
echo -e "  ${BOLD}Poll Interval:${RESET}     ${POLL_INTERVAL}s"
echo ""

section "Pre-flight Checks"

# Check Docker
if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    echo -e "  ${CROSS} Postgres container is NOT running. Aborting."
    exit 1
fi
echo -e "  ${CHECK} Postgres container is running"

if ! docker ps --format '{{.Names}}' | grep -q "^chorus-rabbitmq$"; then
    echo -e "  ${CROSS} RabbitMQ container is NOT running. Aborting."
    exit 1
fi
echo -e "  ${CHECK} RabbitMQ container is running"

if ! command -v jq &> /dev/null; then
    echo -e "  ${CROSS} jq is not installed. Aborting."
    exit 1
fi
echo -e "  ${CHECK} jq is installed"

# Snapshot initial state
INITIAL_PUBLISH_IN=$(get_exchange_publish_in)
echo -e "  ${CHECK} Exchange baseline: ${BOLD}${INITIAL_PUBLISH_IN}${RESET} messages"

# ---------------------------------------------------------------------------
#  Phase 1: Clean Slate
# ---------------------------------------------------------------------------

section "Phase 1: Preparing Clean Slate"

for svc in "${SERVICES[@]}"; do
    local_db="${SERVICE_DB[$svc]}"
    psql_exec "$local_db" "DELETE FROM outbox_events WHERE status IN ('PENDING', 'PUBLISHED');" > /dev/null 2>&1 || true
    remaining=$(psql_exec "$local_db" "SELECT count(*) FROM outbox_events;" 2>/dev/null || echo "?")
    echo -e "  ${CHECK} ${SERVICE_LABEL[$svc]}: outbox cleared"
done

# ---------------------------------------------------------------------------
#  Phase 2: Bulk Insert
# ---------------------------------------------------------------------------

banner "Phase 2: Flood - Inserting $TOTAL_EVENTS Events"

for svc in "${SERVICES[@]}"; do
    local_db="${SERVICE_DB[$svc]}"
    local_event_type="${SERVICE_EVENT_TYPE[$svc]}"
    local_routing_key="${SERVICE_ROUTING_KEY[$svc]}"
    local_color="${SERVICE_COLOR[$svc]}"
    local_label="${SERVICE_LABEL[$svc]}"

    echo -e "  ${SPARK} ${local_color}${BOLD}${local_label}${RESET}: Generating ${EVENTS_PER_SERVICE} events..."

    INSERT_START=$(date +%s%N)

    # Build a single massive INSERT for maximum throughput
    SQL="INSERT INTO outbox_events (id, event_type, routing_key, correlation_id, payload, occurred_at, status) VALUES "
    VALUES=""

    for ((i=1; i<=EVENTS_PER_SERVICE; i++)); do
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
        corr_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
        payload=$(generate_payload "$svc" "$i")
        # Escape single quotes in payload for SQL
        payload_escaped="${payload//\'/\'\'}"

        if [ -n "$VALUES" ]; then
            VALUES+=","
        fi
        VALUES+="('${uuid}', '${local_event_type}', '${local_routing_key}', '${corr_id}', '${payload_escaped}', NOW(), 'PENDING')"

        # Flush every 100 rows to avoid shell argument limits
        if (( i % 100 == 0 )); then
            psql_exec "$local_db" "${SQL}${VALUES};" > /dev/null
            VALUES=""

            pct=$(( i * 100 / EVENTS_PER_SERVICE ))
            printf "\r    Inserting: %b" "$(progress_bar $i $EVENTS_PER_SERVICE "$local_color")"
        fi
    done

    # Flush remaining
    if [ -n "$VALUES" ]; then
        psql_exec "$local_db" "${SQL}${VALUES};" > /dev/null
    fi

    INSERT_END=$(date +%s%N)
    INSERT_MS=$(( (INSERT_END - INSERT_START) / 1000000 ))

    printf "\r    Inserting: %b\n" "$(progress_bar $EVENTS_PER_SERVICE $EVENTS_PER_SERVICE "$local_color")"
    echo -e "    ${DIM}Inserted ${EVENTS_PER_SERVICE} rows in ${INSERT_MS}ms ($(( EVENTS_PER_SERVICE * 1000 / (INSERT_MS + 1) )) rows/s)${RESET}"
    echo ""
done

INSERT_COMPLETE_TIME=$(date '+%H:%M:%S')
info "All ${TOTAL_EVENTS} events inserted at ${BOLD}${INSERT_COMPLETE_TIME}${RESET}"

# Verify counts
echo ""
for svc in "${SERVICES[@]}"; do
    local_db="${SERVICE_DB[$svc]}"
    local_color="${SERVICE_COLOR[$svc]}"
    pending=$(get_pending_count "$local_db")
    echo -e "  ${local_color}${BOLD}${SERVICE_LABEL[$svc]}${RESET}: ${pending} PENDING"
done

# ---------------------------------------------------------------------------
#  Phase 3: Monitor Drain
# ---------------------------------------------------------------------------

banner "Phase 3: Drain - Watching Relay Workers"

info "The relay workers are now racing to publish all ${TOTAL_EVENTS} events."
info "Polling every ${POLL_INTERVAL}s. Timeout: ${DRAIN_TIMEOUT_SECONDS}s."
echo ""

DRAIN_START=$(date +%s)
LAST_TOTAL_PENDING=$TOTAL_EVENTS
STALL_COUNT=0

while true; do
    ELAPSED=$(( $(date +%s) - DRAIN_START ))

    # Gather stats
    ALL_DONE=true
    HEADER="  ${CLOCK} ${DIM}[$(printf '%3d' $ELAPSED)s]${RESET} "
    LINE=""

    CURRENT_TOTAL_PENDING=0

    for svc in "${SERVICES[@]}"; do
        local_db="${SERVICE_DB[$svc]}"
        local_color="${SERVICE_COLOR[$svc]}"
        pending=$(get_pending_count "$local_db")
        published=$(get_published_count "$local_db")
        CURRENT_TOTAL_PENDING=$((CURRENT_TOTAL_PENDING + pending))

        if [ "$pending" -gt 0 ]; then
            ALL_DONE=false
        fi

        LINE+=" ${local_color}${BOLD}$(printf '%-3s' "${svc:0:3}")${RESET}"
        LINE+=" $(progress_bar $published $EVENTS_PER_SERVICE "$local_color")"
        LINE+=" ${DIM}(${published}/${EVENTS_PER_SERVICE})${RESET}  "
    done

    # RabbitMQ stats
    CURRENT_PUBLISH_IN=$(get_exchange_publish_in)
    MESSAGES_THIS_RUN=$((CURRENT_PUBLISH_IN - INITIAL_PUBLISH_IN))

    echo -e "${HEADER}${LINE}${DIM}rmq:${MESSAGES_THIS_RUN}${RESET}"

    if $ALL_DONE; then
        break
    fi

    if [ "$ELAPSED" -ge "$DRAIN_TIMEOUT_SECONDS" ]; then
        echo ""
        echo -e "  ${RED}${BOLD}TIMEOUT after ${DRAIN_TIMEOUT_SECONDS}s! Not all events were drained.${RESET}"
        break
    fi

    # Stall detection
    if [ "$CURRENT_TOTAL_PENDING" -eq "$LAST_TOTAL_PENDING" ]; then
        STALL_COUNT=$((STALL_COUNT + 1))
        if [ "$STALL_COUNT" -ge 10 ]; then
            echo ""
            echo -e "  ${YELLOW}${BOLD}WARNING: No progress for $((STALL_COUNT * POLL_INTERVAL))s. Are the relay workers running?${RESET}"
            STALL_COUNT=0
        fi
    else
        STALL_COUNT=0
    fi
    LAST_TOTAL_PENDING=$CURRENT_TOTAL_PENDING

    sleep "$POLL_INTERVAL"
done

DRAIN_END=$(date +%s)
DRAIN_DURATION=$((DRAIN_END - DRAIN_START))

# ---------------------------------------------------------------------------
#  Phase 4: Results
# ---------------------------------------------------------------------------

banner "Phase 4: Results"

# Final counts
echo -e "  ${DIM}Waiting 5s for RabbitMQ stats to settle...${RESET}"
sleep 5
FINAL_PUBLISH_IN=$(get_exchange_publish_in)
MESSAGES_THIS_RUN=$((FINAL_PUBLISH_IN - INITIAL_PUBLISH_IN))

section "Per-Service Breakdown"

printf "  ${BOLD}%-22s  %10s  %10s  %10s${RESET}\n" "Service" "Inserted" "Published" "Remaining"
printf "  ${DIM}%-22s  %10s  %10s  %10s${RESET}\n" "----------------------" "----------" "----------" "----------"

TOTAL_PUBLISHED=0
TOTAL_REMAINING=0

for svc in "${SERVICES[@]}"; do
    local_db="${SERVICE_DB[$svc]}"
    local_color="${SERVICE_COLOR[$svc]}"
    published=$(get_published_count "$local_db")
    pending=$(get_pending_count "$local_db")
    TOTAL_PUBLISHED=$((TOTAL_PUBLISHED + published))
    TOTAL_REMAINING=$((TOTAL_REMAINING + pending))

    if [ "$pending" -eq 0 ]; then
        status_icon="${CHECK}"
    else
        status_icon="${CROSS}"
    fi

    printf "  ${local_color}%-22s${RESET}  %10d  %10d  %10d  %s\n" \
        "${SERVICE_LABEL[$svc]}" "$EVENTS_PER_SERVICE" "$published" "$pending" "$status_icon"
done

printf "  ${DIM}%-22s  %10s  %10s  %10s${RESET}\n" "----------------------" "----------" "----------" "----------"
printf "  ${BOLD}%-22s  %10d  %10d  %10d${RESET}\n" "TOTAL" "$TOTAL_EVENTS" "$TOTAL_PUBLISHED" "$TOTAL_REMAINING"

section "Performance Metrics"

if [ "$DRAIN_DURATION" -gt 0 ]; then
    THROUGHPUT=$(( TOTAL_PUBLISHED / DRAIN_DURATION ))
else
    THROUGHPUT="$TOTAL_PUBLISHED"
fi

echo -e "  ${BOLD}Drain Duration:${RESET}        ${WHITE}${DRAIN_DURATION}s${RESET}"
echo -e "  ${BOLD}Events Published:${RESET}      ${WHITE}${TOTAL_PUBLISHED}${RESET} / ${TOTAL_EVENTS}"
echo -e "  ${BOLD}Avg Throughput:${RESET}        ${WHITE}${THROUGHPUT} events/s${RESET} (across all services)"
echo -e "  ${BOLD}RabbitMQ Received:${RESET}     ${WHITE}${MESSAGES_THIS_RUN}${RESET} messages"

section "Verdict"

if [ "$TOTAL_REMAINING" -eq 0 ] && [ "$MESSAGES_THIS_RUN" -ge "$TOTAL_EVENTS" ]; then
    echo -e "  ${GREEN}${BOLD}${BLOCK_FULL}${BLOCK_FULL}${BLOCK_FULL} ALL ${TOTAL_EVENTS} EVENTS DRAINED AND DELIVERED ${BLOCK_FULL}${BLOCK_FULL}${BLOCK_FULL}${RESET}"
    echo ""
    echo -e "  Every outbox event was picked up by the relay workers,"
    echo -e "  published to the ${BOLD}chorus.events${RESET} topic exchange, and"
    echo -e "  marked as PUBLISHED in the database. Zero data loss."
elif [ "$TOTAL_REMAINING" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}All events drained from databases, but RabbitMQ count mismatch.${RESET}"
    echo -e "  ${DIM}Expected ${TOTAL_EVENTS} new messages, got ${MESSAGES_THIS_RUN}.${RESET}"
    echo -e "  ${DIM}This may indicate duplicate publishes or a counting offset.${RESET}"
else
    echo -e "  ${RED}${BOLD}${TOTAL_REMAINING} events still PENDING after ${DRAIN_TIMEOUT_SECONDS}s timeout.${RESET}"
    echo -e "  ${DIM}Check that all service relay workers are running.${RESET}"
fi

echo ""
echo -e "  ${DIM}Tip: Open the RabbitMQ Management UI to see the publish spike:${RESET}"
echo -e "  ${DIM}     http://localhost:15672/#/exchanges/%2F/chorus.events${RESET}"
echo ""
