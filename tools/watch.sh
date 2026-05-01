#!/bin/bash
# Periodically query the collector summary + tail recent events.
# Useful as a passive monitor when running long-duration tests.
# Usage: COLLECTOR=http://<collector-host>:9990 ./watch.sh

COLLECTOR="${COLLECTOR:-http://localhost:9990}"
INTERVAL="${INTERVAL:-15}"

echo "watching $COLLECTOR every ${INTERVAL}s — Ctrl+C to stop"
while true; do
  ts=$(date +'%Y-%m-%dT%H:%M:%S')
  summary=$(curl -s -m 3 "$COLLECTOR/summary" 2>/dev/null)
  if [ -z "$summary" ]; then
    echo "$ts — collector unreachable"
  else
    echo "$summary" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'$ts received={d[\"total_received\"]} bg_enter={d[\"bg_enter_count\"]} bg_exit={d[\"bg_exit_count\"]} kinds={list(d[\"by_kind\"].keys())[:8]} since_last={d[\"since_last_event_s\"]}s')
except Exception as e:
    print(f'$ts parse-fail: {e}')
"
  fi
  sleep "$INTERVAL"
done
