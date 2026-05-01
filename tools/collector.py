#!/usr/bin/env python3
"""
ai_debug telemetry collector.

Listens on an HTTP port for POST /event from ai_debug-instrumented apps.
Persists every event as a JSONL line to disk. Exposes GET endpoints for
inspection and summary stats.

Run on a stable host (dev machine, lab box, etc.) reachable from the
device under test on the same network.

Usage:
  python3 collector.py --host 0.0.0.0 --port 9990 \\
      --out /tmp/ai-debug-events.jsonl

Endpoints:
  POST /event              — body is JSON event {kind, ts, payload, ...}
  GET  /events             — last N events as JSON array (?limit=200)
  GET  /events.jsonl       — full JSONL dump
  GET  /summary            — counts by kind and recent fire freq
  GET  /tail               — server-sent events stream of new events
  GET  /health             — ok

The collector is dependency-free (Python 3 stdlib only).
"""

import argparse
import json
import os
import socket
import sys
import threading
import time
from collections import Counter, deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Deque
from urllib.parse import urlparse, parse_qs

# bounded in-memory ring + persistent file write
EVENTS: Deque[dict] = deque(maxlen=10000)
EVENTS_LOCK = threading.Lock()
LIVE_SUBSCRIBERS = []  # list of queues for SSE clients
SUBS_LOCK = threading.Lock()

OUT_PATH = "/tmp/ai-debug-events.jsonl"
SERVER_START_TS = time.time()
TOTAL_RECEIVED = 0


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def append_event(event: dict):
    global TOTAL_RECEIVED
    event.setdefault("collector_received_at", now_iso())
    event.setdefault("collector_received_ms", int(time.time() * 1000))
    with EVENTS_LOCK:
        EVENTS.append(event)
        TOTAL_RECEIVED += 1
    # write to JSONL, flushed
    try:
        with open(OUT_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")
            f.flush()
    except Exception as e:
        sys.stderr.write(f"[collector] write fail: {e}\n")
    # broadcast to SSE subscribers
    line = json.dumps(event, separators=(",", ":"))
    with SUBS_LOCK:
        dead = []
        for q in LIVE_SUBSCRIBERS:
            try:
                q.append(line)
            except Exception:
                dead.append(q)
        for d in dead:
            try:
                LIVE_SUBSCRIBERS.remove(d)
            except ValueError:
                pass
    # always print to stderr so user can tail
    print(json.dumps(event, separators=(",", ":")), flush=True)


def summary() -> dict:
    with EVENTS_LOCK:
        snapshot = list(EVENTS)
    by_kind = Counter()
    by_app = Counter()
    by_isolate = Counter()
    bg_enters = []
    bg_exits = []
    last_event_ms = 0
    for e in snapshot:
        by_kind[e.get("kind", "?")] += 1
        by_app[e.get("app_id", "?")] += 1
        if e.get("isolate"):
            by_isolate[e["isolate"]] += 1
        if e.get("kind") == "bg_enter":
            bg_enters.append(e.get("ts_ms") or e.get("collector_received_ms", 0))
        if e.get("kind") == "bg_exit":
            bg_exits.append(e.get("ts_ms") or e.get("collector_received_ms", 0))
        cm = e.get("collector_received_ms", 0)
        if cm > last_event_ms:
            last_event_ms = cm
    bg_intervals_min = []
    sorted_enters = sorted(bg_enters)
    for i in range(1, len(sorted_enters)):
        bg_intervals_min.append((sorted_enters[i] - sorted_enters[i - 1]) / 60000.0)
    bg_durations_s = []
    paired_count = min(len(bg_enters), len(bg_exits))
    for i in range(paired_count):
        bg_durations_s.append((bg_exits[i] - bg_enters[i]) / 1000.0)
    return {
        "server_uptime_s": int(time.time() - SERVER_START_TS),
        "total_received": TOTAL_RECEIVED,
        "in_memory": len(snapshot),
        "by_kind": dict(by_kind),
        "by_app": dict(by_app),
        "by_isolate": dict(by_isolate),
        "bg_enter_count": len(bg_enters),
        "bg_exit_count": len(bg_exits),
        "bg_intervals_minutes": bg_intervals_min,
        "bg_durations_seconds": bg_durations_s,
        "out_path": OUT_PATH,
        "out_size_bytes": os.path.getsize(OUT_PATH) if os.path.exists(OUT_PATH) else 0,
        "now": now_iso(),
        "last_event_ms": last_event_ms,
        "since_last_event_s": int((time.time() * 1000 - last_event_ms) / 1000) if last_event_ms else None,
    }


class Handler(BaseHTTPRequestHandler):
    def address_string(self):
        # skip reverse DNS — hangs on LAN clients
        return self.client_address[0]

    def log_message(self, fmt, *args):
        # quieter
        sys.stderr.write(f"[{self.client_address[0]}] {fmt % args}\n")

    def _json(self, code: int, body):
        data = json.dumps(body, separators=(",", ":"), default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _text(self, code: int, body: str, content_type="text/plain; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            return self._json(200, {"ok": True, "ts": now_iso()})
        if u.path == "/summary":
            return self._json(200, summary())
        if u.path == "/events":
            qs = parse_qs(u.query)
            limit = int((qs.get("limit") or ["200"])[0])
            kind = (qs.get("kind") or [None])[0]
            with EVENTS_LOCK:
                snap = list(EVENTS)
            if kind:
                snap = [e for e in snap if e.get("kind") == kind]
            return self._json(200, snap[-limit:])
        if u.path == "/events.jsonl":
            try:
                with open(OUT_PATH, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                return self._text(200, "")
            return
        if u.path == "/tail":
            # SSE-ish: stream events as they arrive
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            q = []
            with SUBS_LOCK:
                LIVE_SUBSCRIBERS.append(q)
            try:
                while True:
                    if q:
                        line = q.pop(0)
                        self.wfile.write(f"data: {line}\n\n".encode())
                        try:
                            self.wfile.flush()
                        except BrokenPipeError:
                            return
                    else:
                        time.sleep(0.1)
            except (BrokenPipeError, ConnectionResetError):
                return
            finally:
                with SUBS_LOCK:
                    try:
                        LIVE_SUBSCRIBERS.remove(q)
                    except ValueError:
                        pass
            return
        if u.path == "/":
            return self._text(
                200,
                "ai_debug collector\n"
                "POST /event           — submit event\n"
                "GET  /events?limit=N  — recent events\n"
                "GET  /events.jsonl    — full JSONL\n"
                "GET  /summary         — counts + bg stats\n"
                "GET  /tail            — SSE stream of new events\n"
                "GET  /health          — ok\n",
            )
        return self._text(404, "not found\n")

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/event":
            return self._text(404, "not found\n")
        try:
            length = int(self.headers.get("Content-Length") or "0")
            body = self.rfile.read(length) if length > 0 else b""
            text = body.decode(errors="replace")
            event = json.loads(text)
        except Exception as e:
            sys.stderr.write(
                f"[parse-fail] cl={length} ct={self.headers.get('Content-Type')} "
                f"first120={body[:120]!r}\n"
            )
            return self._json(400, {"error": str(e), "received_bytes": length})
        if not isinstance(event, dict):
            return self._json(400, {"error": "expected JSON object"})
        # also support arrays of events for batched posts
        if isinstance(event.get("events"), list):
            for e in event["events"]:
                if isinstance(e, dict):
                    append_event(e)
            return self._json(200, {"ok": True, "stored": len(event["events"])})
        append_event(event)
        return self._json(200, {"ok": True})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9990)
    parser.add_argument("--out", default="/tmp/ai-debug-events.jsonl")
    args = parser.parse_args()

    global OUT_PATH
    OUT_PATH = args.out

    # touch the output file
    try:
        with open(OUT_PATH, "a"):
            pass
    except Exception as e:
        sys.stderr.write(f"can't open {OUT_PATH}: {e}\n")
        sys.exit(1)

    # find local LAN IP for advertisement
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()
    except Exception:
        local_ip = args.host

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    sys.stderr.write(
        f"ai_debug collector listening on http://{args.host}:{args.port}\n"
        f"  LAN IP: http://{local_ip}:{args.port}\n"
        f"  output: {OUT_PATH}\n"
        f"  endpoints: /event POST, /events, /events.jsonl, /summary, /tail, /health\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nshutting down\n")
        server.shutdown()


if __name__ == "__main__":
    main()
