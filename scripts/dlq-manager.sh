#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Chorus - DLQ Manager CLI
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

RMQ_HOST="localhost:15672"
RMQ_AUTH="guest:guest"
VHOST="%2F"
QUEUE="chorus.dlq"
EXCHANGE="chorus.events"

CMD=${1:-help}

banner() {
    echo ""
    echo -e "${BLUE}${BOLD}======================================================================${RESET}"
    echo -e "${BLUE}${BOLD}  Chorus DLQ Manager${RESET}"
    echo -e "${BLUE}${BOLD}======================================================================${RESET}"
    echo ""
}

case $CMD in
  list)
    banner
    echo -e "  ${MAGENTA}${BOLD}--- Messages in DLQ ---${RESET}"
    echo ""
    
    RESPONSE=$(curl -s -u $RMQ_AUTH "http://$RMQ_HOST/api/queues/$VHOST/$QUEUE/get" \
      -d '{"count":10,"ackmode":"ack_requeue_true","encoding":"auto","truncate":50000}')
      
    if [ "$RESPONSE" == "[]" ] || [ -z "$RESPONSE" ]; then
      echo -e "  ${DIM}No messages in the DLQ.${RESET}"
      echo ""
      exit 0
    fi
    
    echo "$RESPONSE" | jq -c '.[] | { routing_key: .routing_key, original_queue: .properties.headers."x-death"[0].queue, reason: .properties.headers."x-death"[0].reason, payload: (.payload as $p | try ($p | fromjson) catch $p) }' | while read -r line; do
      echo -e "  ${YELLOW}>>${RESET} $line"
    done
    echo ""
    ;;
    
  replay)
    banner
    echo -e "  ${MAGENTA}${BOLD}--- Replaying Next Message ---${RESET}"
    echo ""
    
    # Get 1 message and DON'T requeue (ack_requeue_false) - this consumes it from the DLQ
    MSG=$(curl -s -u $RMQ_AUTH "http://$RMQ_HOST/api/queues/$VHOST/$QUEUE/get" \
      -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto","truncate":50000}')
    
    if [ "$MSG" == "[]" ] || [ -z "$MSG" ]; then
      echo -e "  ${DIM}DLQ is empty. Nothing to replay.${RESET}"
      echo ""
      exit 0
    fi
    
    # Extract routing key and payload
    ORIGINAL_ROUTING_KEY=$(echo "$MSG" | jq -r '.[0].routing_key')
    PAYLOAD=$(echo "$MSG" | jq -r '.[0].payload')
    
    echo -e "  ${CYAN}>>>${RESET} Replaying message with routing key: ${BOLD}$ORIGINAL_ROUTING_KEY${RESET}"
    
    # Escape quotes for JSON payload wrapper
    ESCAPED_PAYLOAD=$(echo "$PAYLOAD" | sed 's/"/\\"/g')
    
    # Re-publish to the main events exchange
    curl -s -u $RMQ_AUTH -H "content-type:application/json" \
      -X POST "http://$RMQ_HOST/api/exchanges/$VHOST/$EXCHANGE/publish" \
      -d "{
        \"properties\": {\"delivery_mode\": 2, \"content_type\": \"application/json\"},
        \"routing_key\": \"$ORIGINAL_ROUTING_KEY\",
        \"payload\": \"$ESCAPED_PAYLOAD\",
        \"payload_encoding\": \"string\"
      }" > /dev/null
      
    echo -e "  ${GREEN}✔ Successfully re-published to $EXCHANGE!${RESET}"
    echo ""
    ;;
    
  replay-all)
    banner
    echo -e "  ${MAGENTA}${BOLD}--- Replaying ALL Messages ---${RESET}"
    echo ""
    
    count=0
    while true; do
      MSG=$(curl -s -u $RMQ_AUTH "http://$RMQ_HOST/api/queues/$VHOST/$QUEUE/get" \
        -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto","truncate":50000}')
        
      if [ "$MSG" == "[]" ] || [ -z "$MSG" ]; then
        break
      fi
      
      ORIGINAL_ROUTING_KEY=$(echo "$MSG" | jq -r '.[0].routing_key')
      PAYLOAD=$(echo "$MSG" | jq -r '.[0].payload')
      ESCAPED_PAYLOAD=$(echo "$PAYLOAD" | sed 's/"/\\"/g')
      
      curl -s -u $RMQ_AUTH -H "content-type:application/json" \
        -X POST "http://$RMQ_HOST/api/exchanges/$VHOST/$EXCHANGE/publish" \
        -d "{
          \"properties\": {\"delivery_mode\": 2, \"content_type\": \"application/json\"},
          \"routing_key\": \"$ORIGINAL_ROUTING_KEY\",
          \"payload\": \"$ESCAPED_PAYLOAD\",
          \"payload_encoding\": \"string\"
        }" > /dev/null
        
      count=$((count + 1))
      echo -n "."
    done
    
    echo -e "\n\n  ${GREEN}✔ Replayed $count messages successfully!${RESET}"
    echo ""
    ;;
    
  clear)
    banner
    echo -e "  ${MAGENTA}${BOLD}--- Clearing DLQ ---${RESET}"
    echo ""
    
    curl -s -u $RMQ_AUTH -X DELETE "http://$RMQ_HOST/api/queues/$VHOST/$QUEUE/contents" > /dev/null
    
    echo -e "  ${GREEN}✔ DLQ cleared successfully!${RESET}"
    echo ""
    ;;
    
  *)
    echo "Usage: ./dlq-manager.sh [list|replay|replay-all|clear]"
    ;;
esac
