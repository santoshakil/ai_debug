# ai_debug

An in-app debugging bridge for Flutter with an embedded MCP Streamable HTTP
server and browser dashboard. It is one Flutter package implemented entirely
in Dart. It has no Rust, FFI, protobuf, native plugin, code generation, or
helper process.

## What it includes

- MCP tools, small REST endpoints, and a live browser dashboard
- bounded logs plus Flutter, platform, and explicitly recorded error history
- process RSS, image cache, scheduler, display, and timer-lag samples
- refresh-rate-aware frame timings, FPS, missed frames, percentiles, and raster
  cache measurements
- bounded widget, render, debug-layer, semantics, and focus inspection
- semantics-first tap, double-tap, long-press, drag, pinch, scroll, wait, and
  action runs
- explicit state, route, network, screenshot, trace, and isolate support
- optional VM service CPU, memory, allocation, stack, isolate, and timeline tools
- opt-in file reads, outbound probes, telemetry forwarding, and mDNS discovery

## Install

```yaml
dependencies:
  ai_debug:
    git:
      url: https://github.com/santoshakil/ai_debug.git
```

For local development:

```yaml
dependencies:
  ai_debug:
    path: ../ai_debug
```

## Start

Initialize Flutter first. Keep the token in an ignored local environment file
and pass it as a Dart define; process environment variables are not available
through `String.fromEnvironment` unless they are passed explicitly.

```dart
import 'package:ai_debug/ai_debug.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const _requested = bool.fromEnvironment('AI_DEBUG');
const _token = String.fromEnvironment('AI_DEBUG_TOKEN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kReleaseMode && _requested && _token.length >= 32) {
    await AiDebug.start(
      config: AiDebugConfig(
        appId: 'my_app',
        port: 9999,
        token: _token,
        features: const AiDebugFeatures(
          automation: true,
          navigation: true,
          network: true,
          screenshots: true,
          vmService: true,
        ),
        automation: const UiAutomationConfig(allowInput: false),
      ),
    );
  }
  runApp(const MyApp());
}
```

```bash
export AI_DEBUG_TOKEN='use-a-long-local-secret'
flutter run \
  --dart-define=AI_DEBUG=true \
  --dart-define=AI_DEBUG_TOKEN="$AI_DEBUG_TOKEN"
```

`AiDebugConfig` creates a random 32-byte access token when `token` is omitted.
Read `AiDebug.token` after startup and give it only to the local MCP client or
dashboard. A fixed local token is easier for repeated development runs. Do not
log or ship either token.

```dart
await AiDebug.start(appId: 'my_app');
final accessToken = AiDebug.token;
final port = AiDebug.endpointPort;
```

Clients send the token as `Authorization: Bearer <token>` or
`X-AI-Debug-Token: <token>`. The safe default binds to `127.0.0.1`. A
non-loopback bind also requires `unsafeLan: true`; the server still uses plain
HTTP, so use it only on a trusted development network.
For a wildcard bind, add every direct IP or DNS authority clients will use to
`allowedHosts`; the generated mDNS hostname is accepted automatically. Keep
`allowedOrigins` limited to exact browser origins that need cross-origin API
access. Same-origin dashboard requests work without adding an origin.

Release builds are blocked by default even if startup is called. Setting
`allowRelease: true` is an explicit override and should be limited to a
controlled internal build.

## Feature gates

The default `AiDebugFeatures()` exposes read-only diagnostics, logs, state,
resource, frame, UI, trace, lifecycle, and cooperative isolate views. The
`resources` gate contains the in-process DevTools views. These remote tools and
discovery paths are off until enabled:

- `screenshots`: capture the configured root or current render view
- `automation`: inspect semantics and send bounded pointer actions
- `navigation`: use the app-provided route adapter
- `network`: track instrumented requests and run outbound probes
- `files`: read only inside explicit absolute `allowedFileRoots`
- `runtimeControls`: add controls to enabled read gates, plus time dilation,
  overlay, clipboard, haptics, and system sound
- `telemetry`: start a collector, then send bounded events to HTTPS or loopback HTTP
- `vmService`: connect to the current Dart VM service when one is available
- `discovery`: advertise a non-loopback, `unsafeLan` server with mDNS

Use `AiDebugFeatures.none()` for an allow-list setup. `AiDebugFeatures.all()`
enables every gate except discovery and requires at least one
`allowedFileRoots` entry. Pass `files: false` when file access is not needed.
Pass `discovery: true` to include discovery.

The default server advertises 31 remote tools. `none()` advertises only the
transport-managed `list_apps` tool. `all()` advertises 104 tools. See the
[tool reference](doc/tools.md) for the exact gate matrix.

## App adapters

`state.*` exposes only registered state sources. Register safe snapshots and
redact anything private.

```dart
AiDebug.registerStateSource(StateSource(
  name: 'session',
  snapshot: () => {'signedIn': session.isSignedIn},
  changesFactory: () => session.changes,
));

AiDebug.setNavigation(NavigationAdapter(
  snapshot: () => {'route': router.current.name},
  navigate: (location, _) => router.navigatePath(location),
  back: router.maybePopTop,
));
```

Explicit network tracking stores method, scheme, host, port, path, query keys,
duration, status, and byte counts. It removes user info and fragments and
replaces every query value with `[redacted]`. Paths and query keys can still
contain private data. It does not capture headers or bodies.

```dart
final request = AiDebug.trackNetwork(method: 'GET', uri: uri);
try {
  final response = await client.get(uri);
  request.finish(
    status: response.statusCode,
    responseBytes: response.bodyBytes.length,
  );
} catch (error) {
  request.fail(error);
  rethrow;
}
```

For stable automation selectors, wrap important controls with `AiDebugTarget`
and use its identifier in `ui.*` tools.
Unlabeled nodes can be targeted by the `id` and `view_id` pair returned by
`ui.snapshot` or `ui.find`. That pair remains valid only while the Flutter
semantics node stays attached.

`UiAutomationConfig.enabled` controls automation. `allowInput: false` keeps
inspection but blocks input. Raw coordinates and text-field values are off by
default. All action and snapshot limits are configurable and bounded.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/` or `/dashboard` | local live dashboard |
| `GET` | `/healthz` | readiness |
| `GET` | `/api/tools` | tool definitions |
| `GET` | `/api/logs` | bounded Dart logs |
| `POST` | `/api/cmd/<name>` | direct tool call |
| `GET`, `HEAD` | `/api/file?path=...` | allowed-root file stream with ranges |
| `POST` | `/mcp` | MCP Streamable HTTP requests |
| `DELETE` | `/mcp` | close a legacy MCP session |

The dashboard shell and `/healthz` are public but return no debug data. Every
other endpoint requires the access token.

`/api/file` returns `416` when the full file or requested range exceeds
`maxResultBytes`, which defaults to 4 MiB.

The MCP server supports stateless revision `2026-07-28` and legacy revisions
`2025-03-26`, `2025-06-18`, and `2025-11-25`. Configure the client for
Streamable HTTP at the bound `/mcp` URL. Revision `2026-07-28` can start with
`server/discover` or call tools directly; legacy clients use `initialize` and
then `notifications/initialized`. Later legacy requests include the returned
`Mcp-Session-Id` and negotiated `MCP-Protocol-Version` headers.
Server-sent event streaming is not implemented.

## Documentation

- [Integration guide](doc/integration.md)
- [Tool and feature reference](doc/tools.md)
- [Security policy](SECURITY.md)
- [Change history](CHANGELOG.md)

## Feature safety

- All histories, snapshots, queues, request bodies, results, and action runs
  have fixed limits.
- A timed-out tool keeps the serial tool slot until its handler settles because
  Dart futures cannot be cancelled safely.
- Network history covers only requests passed through `AiDebug.trackNetwork`.
- State history covers only registered state sources.
- Frame timings cannot attribute a frame to one view in a multi-view engine.
- RSS is whole-process memory. CPU, Dart heap, allocation, GC, and full engine
  timelines need the optional VM service tools.
- `vm.cpu` also needs the VM sampling profiler to be enabled.
- GPU, thermal, battery, native heap, arbitrary platform-channel inspection,
  and host-level network traffic are outside this Dart package.
- The package requires `dart:io`; Flutter web is not supported.
- Debug or profile mode gives the useful Flutter and VM inspection data.

## Verify

```bash
dart format --set-exit-if-changed lib test example
flutter analyze
flutter test
dart pub publish --dry-run
```

## License

MIT. See [LICENSE](LICENSE).
