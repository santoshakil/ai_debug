#!/bin/bash
# Live-tail the collector's SSE stream with pretty-printed event lines.
# Usage:
#   COLLECTOR=http://<collector-host>:9990 ./tail.sh
#   ./tail.sh                        # defaults to localhost:9990
#   ./tail.sh | grep bg              # filter as needed
#
# Each line is one event:
#   HH:MM:SS  [isolate]  kind             short-message

set -u
COLLECTOR="${COLLECTOR:-http://localhost:9990}"

echo "tailing $COLLECTOR/tail — Ctrl+C to stop" >&2

curl --no-buffer -s "$COLLECTOR/tail" | python3 -u -c '
import sys, json
for raw in sys.stdin:
    raw = raw.strip()
    # SSE format: "data: {json}"  blank lines separate events
    if not raw.startswith("data:"):
        continue
    body = raw[5:].strip()
    if not body:
        continue
    try:
        e = json.loads(body)
    except Exception:
        print(f"  ?? {body[:100]}")
        continue
    iso = (e.get("ts_iso") or "")[11:19] or "--:--:--"
    iso_id = (e.get("isolate") or "?")[:5]
    kind = (e.get("kind") or "?")[:22]
    p = e.get("payload") or {}
    msg = (p.get("message") or "").strip()
    if not msg:
        # fall back to compact payload preview
        items = [(k, v) for k, v in p.items() if k not in ("error", "stack")]
        msg = " ".join(f"{k}={v}" for k, v in items[:6])
    msg = msg[:80]
    level = (p.get("level") or "").strip()
    level_tag = f" [{level[:7]:<7s}]" if level else ""
    print(f"{iso}  [{iso_id:<5s}] {kind:<22s}{level_tag}  {msg}")
'
