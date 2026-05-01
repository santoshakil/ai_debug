#!/usr/bin/env python3
"""Analyze ai_debug collector events.jsonl for patterns + indicators.

Usage:
  python3 analyze.py /tmp/ai-debug-events.jsonl
  cat events.jsonl | python3 analyze.py /dev/stdin
  ssh user@collector-host 'cat /tmp/ai-debug-events.jsonl' | python3 analyze.py /dev/stdin

Output sections:
  - events by kind / isolate / app
  - background-isolate run summary (boots, intervals)
  - log entries grouped by template-collapsed pattern (UUIDs/numbers normalized)
  - error class distribution
  - heartbeat time-series (if telemetry includes monitor_heartbeat events)
  - generic indicators: error/warning hot spots, recurring failure patterns
"""
import json
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <events.jsonl>")
        sys.exit(1)

    path = sys.argv[1]
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except Exception as e:
                print(f"  parse fail on line: {e}", file=sys.stderr)

    if not events:
        print("no events")
        return

    print(f"=== ai_debug telemetry analysis ({len(events)} events) ===\n")

    # by kind
    by_kind = Counter(e.get("kind", "?") for e in events)
    print("=== events by kind ===")
    for k, v in by_kind.most_common():
        print(f"  {v:5d}  {k}")
    print()

    # by isolate
    by_isolate = Counter(e.get("isolate", "?") for e in events)
    print("=== events by isolate ===")
    for k, v in by_isolate.most_common():
        print(f"  {v:5d}  {k}")
    print()

    # by app
    by_app = Counter(e.get("app_id", "?") for e in events)
    print("=== events by app ===")
    for k, v in by_app.most_common():
        print(f"  {v:5d}  {k}")
    print()

    # bg lifecycle
    bg_events = [e for e in events if e.get("isolate") == "bg"]
    if bg_events:
        print(f"=== BG isolate events ({len(bg_events)}) ===")
        for e in bg_events[:20]:
            iso = (e.get("ts_iso", "") or "")
            iso_short = iso[11:19] if len(iso) >= 19 else iso
            p = e.get("payload", {})
            msg = p.get("message", "")[:80]
            print(f"  {iso_short} {e.get('kind','?'):25s} {msg}")
        print()

        # bg run reconstruction
        bg_boots = [e for e in bg_events if e.get("kind") == "bg_isolate_boot"]
        bg_done = [e for e in bg_events if "entrypoint_done" in (e.get("payload", {}).get("message") or "")]
        bg_err = [e for e in bg_events if "entrypoint_error" in (e.get("payload", {}).get("message") or "")]
        print(f"=== BG run summary ===")
        print(f"  boots: {len(bg_boots)}")
        print(f"  done: {len(bg_done)}")
        print(f"  errored: {len(bg_err)}")

        # intervals between boots
        if len(bg_boots) > 1:
            times = sorted([b.get("ts_ms", 0) for b in bg_boots])
            intervals = [(times[i] - times[i - 1]) / 60000.0 for i in range(1, len(times))]
            print(f"  intervals_between_boots_min: {[f'{x:.1f}' for x in intervals]}")
        print()

    # log entries — bug pattern grouping
    logs = [e for e in events if e.get("kind") == "log"]
    if logs:
        print(f"=== log entries ({len(logs)}) ===")
        levels = Counter()
        for e in logs:
            p = e.get("payload", {})
            levels[p.get("level", "?")] += 1
        print(f"by level: {dict(levels)}")
        print()

        # pattern grouping
        patterns = Counter()
        sample_for_pattern = {}
        for e in logs:
            p = e.get("payload", {})
            msg = p.get("message", "")
            pattern = re.sub(r"[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}", "<UUID>", msg)
            pattern = re.sub(r"/L0/\d+", "/L0/X", pattern)
            pattern = re.sub(r"\d{4,}", "<NUM>", pattern)
            pattern = pattern[:80]
            patterns[pattern] += 1
            if pattern not in sample_for_pattern:
                sample_for_pattern[pattern] = e
        print("=== log patterns (most common) ===")
        for pat, cnt in patterns.most_common(20):
            samp = sample_for_pattern[pat]
            sp = samp.get("payload", {})
            level = sp.get("level", "?")
            logger = sp.get("logger", "?")
            print(f"  {cnt:4d}x  [{level:8s}] {logger}: {pat}")
        print()

        # error class distribution
        err_classes = Counter()
        for e in logs:
            p = e.get("payload", {})
            err = p.get("error", "")
            if err:
                m = re.match(r"^([A-Za-z]+(?:Exception|Error)?)", err)
                if m:
                    err_classes[m.group(1)] += 1
        if err_classes:
            print("=== error classes ===")
            for k, v in err_classes.most_common():
                print(f"  {v:4d}x  {k}")
            print()

    # heartbeats — time series
    hbs = [e for e in events if e.get("kind") == "monitor_heartbeat"]
    if hbs:
        print(f"=== heartbeats ({len(hbs)}) — time series ===")
        for h in hbs[-10:]:
            iso = h.get("ts_iso", "") or ""
            iso_short = iso[11:19] if len(iso) >= 19 else iso
            p = h.get("payload", {})
            print(f"  {iso_short} hashed={p.get('hashed','?')} back={p.get('backup_back','?')} items={p.get('items','?')} icloud={p.get('icloud','?')} remote={p.get('remote','?')} ipad={p.get('ipad_alive','?')}")
        # Compute hash rate
        if len(hbs) > 1:
            try:
                first = hbs[0]
                last = hbs[-1]
                first_h = int(first.get("payload", {}).get("hashed", "0") or 0)
                last_h = int(last.get("payload", {}).get("hashed", "0") or 0)
                first_t = first.get("ts_ms", 0)
                last_t = last.get("ts_ms", 0)
                if last_t > first_t and last_h > first_h:
                    rate_min = (last_h - first_h) / ((last_t - first_t) / 60000.0)
                    print(f"  hash rate: {rate_min:.1f} assets/min over {(last_t-first_t)/60000.0:.1f} min")
            except Exception as e:
                pass
        print()

    # generic failure indicators
    if logs:
        print("=== failure indicators ===")
        severe_n = sum(1 for e in logs if (e.get("payload", {}).get("level") or "") in ("SEVERE", "SHOUT"))
        warning_n = sum(1 for e in logs if (e.get("payload", {}).get("level") or "") == "WARNING")
        with_err = sum(1 for e in logs if e.get("payload", {}).get("error"))
        with_stack = sum(1 for e in logs if e.get("payload", {}).get("stack"))
        null_check = sum(1 for e in logs if "Null check operator" in (e.get("payload", {}).get("error") or ""))
        tool_failed = sum(1 for e in logs if 'tool "' in (e.get("payload", {}).get("message") or "") and "failed" in (e.get("payload", {}).get("message") or ""))
        if severe_n: print(f"  SEVERE+ entries:        {severe_n}")
        if warning_n: print(f"  WARNING entries:        {warning_n}")
        if with_err: print(f"  entries with error:     {with_err}")
        if with_stack: print(f"  entries with stack:     {with_stack}")
        if null_check: print(f"  Null-check NPE:         {null_check}")
        if tool_failed: print(f"  ai_debug tool failures: {tool_failed}")
        print()

    # recent activity
    if events:
        latest = events[-1].get("collector_received_at", "")
        first = events[0].get("collector_received_at", "")
        print(f"=== timeline ===")
        print(f"  first: {first}")
        print(f"  latest: {latest}")
        # Use collector_received_ms to span correctly (ts_ms can be from test events)
        col_ts = [e.get("collector_received_ms", 0) for e in events if e.get("collector_received_ms", 0) > 1700000000000]
        if len(col_ts) >= 2:
            span_min = (max(col_ts) - min(col_ts)) / 60000.0
            print(f"  total span: {span_min:.1f} min ({len(col_ts)} valid timestamps)")


if __name__ == "__main__":
    main()
