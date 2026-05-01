# ai_debug

Embedded MCP debug bridge for Flutter apps. Lets an AI agent (Claude Code, etc.) tail your app's logs and invoke functions inside a running app — for autonomous debugging, scripted reproduction, and live exploration.

- **Server**: Rust (`axum` + `rmcp`) embedded in the app's dylib. No external binary, no extra process.
- **Transport**: MCP Streamable HTTP (2025-03-26) over `POST /mcp`, plus a plain REST surface. mDNS advertised as `_ai-debug._tcp.local.`.
- **Integration**: 3 lines in `main.dart` + per-feature `AiDebug.register(...)`.
- **Telemetry collector**: stdlib-only Python server in `tools/` that ingests events pushed from the app — useful for long-running tests where the bridge itself may go down.

> Status: alpha (`0.1.0`). Used in production debugging of a real-world Flutter app (~155 tools registered, multi-isolate telemetry, ~2k events/session). API surface may shift before `1.0`.

## Architecture

```
MCP client (Claude)            Flutter app (iOS / Android / desktop)
───────────────────            ──────────────────────────────────────
HTTP + Streamable HTTP         Dart: ai_debug package
                                 - Logger.root → ring buffer
                                 - CommandRegistry (tool defs)
                                 - NativeEventReceiver
                                       │ FFI (prost)
                                       ▼
                               Rust: ai_debug crate (cdylib)
                                 - tokio static Runtime
                                 - axum + rmcp (MCP server, /mcp)
                                 - tracing Layer → ring buffer
                                 - NativeEventPort (irondash)
                                 - mdns-sd advertise
```

A separate, optional **collector** at `tools/collector.py` ingests JSON events POSTed by the in-app telemetry pusher to a stable host on your LAN — useful when the device under test is being kicked around (background isolates, terminations, network flaps) and you want a durable record outside the app process.

## Quick start

```bash
git clone https://github.com/santoshakil/ai_debug.git
cd ai_debug
./scripts/setup.sh             # installs protoc + dart deps
cargo build -p ai_debug        # builds the cdylib + cbindgen header
cd examples/minimal_app
flutter pub get
flutter run                    # starts the app + ai_debug HTTP server on :9999
```

In your MCP client config (`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "ai-debug": {
      "type": "sse",
      "url": "http://localhost:9999/mcp"
    }
  }
}
```

Sanity check from a terminal:

```bash
curl http://localhost:9999/healthz                          # → ok
curl http://localhost:9999/api/tools | jq .tools[].name     # → list of registered tools
curl -X POST http://localhost:9999/api/cmd/<tool> -d '{}'   # → invoke a tool
```

## Integration into an existing Flutter app

```yaml
# pubspec.yaml
dependencies:
  ai_debug:
    git:
      url: https://github.com/santoshakil/ai_debug.git
      path: flutter/packages/ai_debug
```

```dart
// main.dart
import 'package:ai_debug/ai_debug.dart';
import 'package:flutter/foundation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    await AiDebug.start(appId: 'my_app');
  }
  runApp(const MyApp());
}
```

Register custom tools anywhere:

```dart
AiDebug.register(
  name: 'navigate',
  description: 'Push a route',
  inputSchema: AiDebugSchema.object({
    'path': AiDebugSchema.string(),
  }, required: ['path']),
  handler: (args) async {
    await router.push(args['path'] as String);
    return {'ok': true};
  },
);
```

See [`docs/integration.md`](docs/integration.md) for platform-specific dylib loading (macOS / iOS / Android).

## REST endpoints

| method      | path             | purpose                                                                                                          |
|-------------|------------------|------------------------------------------------------------------------------------------------------------------|
| GET         | `/healthz`       | plaintext `ok`                                                                                                   |
| GET         | `/api/tools`     | JSON list of registered tools (shape compatible with MCP `tools/list`)                                           |
| GET         | `/api/logs`      | merged Rust + Dart log tail (`?limit=&level=&grep=&source=&since_ms=`)                                           |
| POST        | `/api/cmd/:name` | invoke a Dart tool with JSON body args                                                                           |
| **GET/HEAD**| **`/api/file`**  | **stream an absolute file path off the device. `Range` header supported (resume + parallel chunks). HEAD = stat.** |
| POST        | `/mcp`           | **MCP JSON-RPC** (Streamable HTTP transport, MCP 2025-03-26)                                                     |

## Built-in tools

The Dart package ships with a small set of always-on tools. Register them with `registerBuiltinTools(registry)` (called by `AiDebug.start()` by default):

| group | tools                                                                                                  |
|-------|--------------------------------------------------------------------------------------------------------|
| logs  | `log_tail`, `log_grep`, `log_clear`                                                                    |
| time  | `time_now`, `time_uptime`                                                                              |
| net   | `network_http_get`, `network_http_post_json`, `network_dns_lookup`, `network_self_ips`, `network_check_port` |
| rt    | `runtime_info`, `runtime_isolate_id`, `runtime_gc_hint`, `vm_force_gc`, `vm_isolate_id`                |
| fs    | `fs_app_dirs`, `fs_listing`, `fs_walk`, `fs_stat`, `fs_dir_size`, `fs_read_text`, `fs_read_bytes`, `fs_disk_free` |
| chan  | `platform_invoke` — invoke an arbitrary Flutter MethodChannel from outside the app                     |
| tlm   | `telemetry_start`, `telemetry_stop`, `telemetry_status`, `telemetry_emit`, `telemetry_flush`           |

## Pulling files off the device

For anything bigger than a few MB (sqlite DBs, log dumps, exports), use the streaming endpoint — it pipes bytes kernel → socket via `tokio::fs::File` + `tokio_util::io::ReaderStream`, with no Dart heap involvement and no base64 bloat.

```bash
# stat first
curl -sI "http://<bridge-host>:9999/api/file?path=/abs/path/on/device"

# pull (saves with Content-Disposition filename via -OJ)
curl -OJ "http://<bridge-host>:9999/api/file?path=/abs/path/on/device"

# resume after interruption
curl -OJC - "http://<bridge-host>:9999/api/file?path=/abs/path/on/device"

# parallel chunks (4 workers)
curl -r 0-      -o part0 "..." &
curl -r 1048576-2097151 -o part1 "..." &
# ... reassemble with `cat part* > whole`
```

Path policy: must be absolute, must not contain `..`, must point to a regular file. The bridge runs in debug mode only — it can read anything the app process can read. Don't expose port 9999 outside your dev network.

For extracting an in-app sqlite DB without races against running writers, your app's tool registrations should pair this endpoint with a `VACUUM INTO 'snapshot.db'` call (see the [Immich case study](case-studies/immich/) for a worked `db_snapshot` example).

For very small files (`<` few MB), the `fs_read_bytes` Dart tool returns base64 chunks via the regular tool-call channel — simpler when you don't want a side-channel HTTP request.

## Telemetry collector

For long-running tests where the bridge itself may go down (background isolate fires, app terminations, sustained-load hangs), use the in-app **telemetry pusher** + Mac-side **collector**:

```bash
# on the collector host (Mac, Linux, lab box)
python3 tools/collector.py --host 0.0.0.0 --port 9990 --out /tmp/ai-debug-events.jsonl
```

```dart
// in your Flutter app, anywhere after AiDebug.start()
AiDebug.startTelemetry(
  collectorUrl: 'http://<collector-host>:9990',
  appId: 'my_app',
  isolate: 'main',  // or 'bg' from a background isolate entrypoint
);
```

The pusher subscribes to `Logger.root` (warnings + above) plus `WidgetsBindingObserver` lifecycle events, batches them, and POSTs to the collector. Uses raw socket HTTP/1.1 to work around an iOS `dart:io` `HttpClient` bug where the request body is dropped (`Content-Length: 0`). Bounded retry queue, 2s flush interval.

The collector is **stdlib-only Python 3** — no `pip install` required. Endpoints:

| method | path              | purpose                                              |
|--------|-------------------|------------------------------------------------------|
| POST   | `/event`          | append a JSON event to the JSONL log                 |
| GET    | `/events`         | last N events (`?limit=200&kind=&isolate=`)          |
| GET    | `/events.jsonl`   | full JSONL dump                                      |
| GET    | `/summary`        | counts by kind + recent activity                     |
| GET    | `/tail`           | server-sent event stream of new events               |
| GET    | `/health`         | `ok`                                                 |

Three helpers ship next to it:

- **`tools/tail.sh`** — live SSE stream, one line per event. Best for watching as things happen:
  ```bash
  COLLECTOR=http://<collector-host>:9990 ./tools/tail.sh
  # 07:10:11  [main ]  bg_isolate_boot          [INFO   ]  elapsedMs=270
  # 07:10:13  [bg   ]  log                      [WARNING]  upload failed: timeout
  # 07:10:14  [main ]  monitor_heartbeat                   hashed=4936 remote=7142
  ```
  Pipe through `grep` to filter (`| grep bg`, `| grep -E 'WARNING|SEVERE'`).
- **`tools/watch.sh`** — periodic curl loop over `/summary`, suitable for `tail -f`-style observation when you want aggregates rather than per-event.
- **`tools/analyze.py`** — reads a JSONL dump, prints event histograms, log pattern grouping (UUID/number-collapsed templates), error class distribution, and generic failure indicators.

## Case study: testing with Immich

This library was developed and stress-tested against [Immich](https://github.com/immich-app/immich)'s Flutter client to debug iOS background sync, iCloud upload behavior, and engine-collision issues. ~130 tool registrations across 22 files, ~2k telemetry events captured per overnight session, multiple background-isolate fires recorded with full timeline per fire.

The Immich-specific tool registrations live in a dedicated repo that gets mounted **two ways**:
- As a submodule inside an Immich fork at `mobile/lib/utils/ai_debug/` — the `.dart` files become real Immich source there.
- As a submodule of this repo at `case-studies/immich/` — same content, used here as worked-example reference.

Repo: [`immich_ai_debug_tools`](https://github.com/santoshakil/immich_ai_debug_tools).

## Platform support

| target              | status    | notes                                                                                                |
|---------------------|-----------|------------------------------------------------------------------------------------------------------|
| macOS (desktop)     | ✅ tested  | `cargo build` + `AI_DEBUG_DYLIB=...` env var                                                         |
| iOS (device)        | ✅ tested  | static link via `native_toolchain_rust` hook                                                         |
| iOS (simulator)     | ✅ tested  |                                                                                                      |
| Android (arm64)     | ✅ tested  | NDK cross-compile via `native_toolchain_rust` hook. `adb forward tcp:19999 tcp:9999` for host access |
| Linux               | 🟡 wip    |                                                                                                      |
| Windows             | 🟡 wip    |                                                                                                      |

## Roadmap

- ✅ **Phase 1** — Rust cdylib + axum + tracing ring buffer + NativeEventPort + mDNS
- ✅ **Phase 1.5** — Dart log query via NativeEventPort → merged `/api/logs`
- ✅ **Phase 2** — Dart tool invocation via `POST /api/cmd/:name`
- ✅ **Phase 2.5** — `rmcp` `ServerHandler` + `StreamableHttpService` at `/mcp` with dynamic tool discovery
- ✅ **Phase 2.7** — Telemetry pusher + Python collector + analyzer
- ⏳ **Phase 3** — Screenshot, widget tree dump, riverpod-state inspectors
- ⏳ **Phase 4** — VM Service proxy (hot reload, Dart expression eval) — optional, big

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Issues + PRs welcome.

## License

MIT — see [`LICENSE`](LICENSE).
