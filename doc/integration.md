# Integration

## Add the package

```yaml
dependencies:
  ai_debug:
    git:
      url: https://github.com/santoshakil/ai_debug.git
```

For a neighboring checkout, replace the Git source with `path: ../ai_debug`.
The path must exist in every checkout and CI environment that resolves the app.

## Keep local settings out of Git

Use one long token for local runs. This project ignores `.env`, `.env.*`, and
`mise.local.toml`.

```bash
mise set --file mise.local.toml AI_DEBUG=true
mise set --file mise.local.toml --prompt AI_DEBUG_TOKEN
```

Environment values must still be passed as Dart defines:

```bash
mise exec -- sh -c 'exec flutter run \
  --dart-define=AI_DEBUG="$AI_DEBUG" \
  --dart-define=AI_DEBUG_TOKEN="$AI_DEBUG_TOKEN"'
```

## Start the bridge

Start after Flutter binding setup and after any app-owned global error handlers
that ai_debug should preserve.

```dart
import 'package:ai_debug/ai_debug.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const _requested = bool.fromEnvironment('AI_DEBUG');
const _token = String.fromEnvironment('AI_DEBUG_TOKEN');

Future<void> startLocalDebug() async {
  if (kReleaseMode || !_requested || _token.length < 32) return;

  await AiDebug.start(
    config: AiDebugConfig(
      appId: 'my_app',
      token: _token,
      features: const AiDebugFeatures(
        automation: true,
        navigation: true,
        network: true,
        screenshots: true,
      ),
      automation: const UiAutomationConfig(allowInput: false),
    ),
  );
}
```

`allowInput: false` keeps automation inspection-only. Enable input only for a
controlled test build. Release startup fails unless `allowRelease: true` is
also set.

## Register app data

The package does not scan arbitrary state, routes, or network clients. Register
only values that are safe to expose.

```dart
AiDebug.registerStateSource(
  StateSource(
    name: 'app.session',
    snapshot: () => {'signedIn': session.isSignedIn},
    changesFactory: () => session.changes,
  ),
);

AiDebug.setNavigation(
  NavigationAdapter(
    snapshot: () => {'route': router.current.name},
    navigate: (location, _) => router.navigatePath(location),
    back: router.maybePopTop,
  ),
);
```

Use `sensitive: true` to replace a state value with `[redacted]`, or provide a
bounded `redactor`. Do not expose identity data, tokens, endpoints, headers, or
route arguments.

Custom tools must be registered before `AiDebug.start`. State sources,
navigation, and screenshot adapters may be attached when their app objects are
ready. Clear or unregister app-owned adapters when their lifecycle ends.

## Track app network calls

Only explicit tracking is recorded. Requests are not intercepted globally.

```dart
final tracked = AiDebug.trackNetwork(method: request.method, uri: request.url);
try {
  final response = await client.send(request);
  tracked.finish(status: response.statusCode);
  return response;
} catch (error) {
  tracked.fail(error);
  rethrow;
}
```

Query values, user info, and fragments are removed; path segments are retained.
Headers and bodies are not stored. Use an HTTP client wrapper so success,
stream failure, and cancellation finish each tracked request exactly once.

## Stable UI targets and screenshots

```dart
AiDebugTarget(
  id: 'login.submit',
  child: FilledButton(onPressed: login, child: const Text('Login')),
)
```

Automation uses semantics selectors first. Raw coordinates and text-field
values are disabled by default. For a fixed screenshot area, attach a
`GlobalKey` to a `RepaintBoundary` and pass it to `AiDebug.setScreenshotRoot`.

## Add custom tools

Register custom tools before startup. Names, schemas, annotations, and results
are validated and bounded. An output schema, when supplied, must describe an
object.

```dart
AiDebug.register(
  name: 'session.refresh',
  description: 'Refresh the current session.',
  inputSchema: AiDebugSchema.empty(),
  annotations: const {
    'readOnlyHint': false,
    'destructiveHint': false,
    'openWorldHint': true,
  },
  handler: (_) async => {'refreshed': await session.refresh()},
);
```

Custom registrations survive `AiDebug.dispose`. Call `unregister` or
`clearRegisteredTools` before the next start when they should be removed.

## Record errors and traces

`recordError` adds an app-owned failure to bounded error history. `runGuarded`
records uncaught zone failures and still invokes its optional app callback.

```dart
AiDebug.recordError(error, stack, source: 'sync');

AiDebug.startTracing();
final value = await AiDebug.traceAsync('sync.refresh', refresh);
AiDebug.traceInstant('sync.ready');
AiDebug.stopTracing();
```

Trace events are kept in a bounded in-process recorder and can be exported as
Chrome Trace JSON. Full VM, engine, compiler, and GC events require VM service
tools.

## Attach child isolates

Pass `AiDebug.isolatePort` to an isolate explicitly, then attach there. Static
state is isolate-local, so existing isolates are not discovered automatically.

```dart
final client = AiDebug.attachIsolate(hub, name: 'thumbnail-worker');
client.event('ready');
try {
  await work();
} catch (error, stack) {
  client.error(error, stack);
} finally {
  client.dispose();
}
```

## Forward telemetry

Telemetry is off until both its feature and collector are enabled. It sends
bounded explicit events and does not capture logs or lifecycle by default.

```dart
AiDebug.startTelemetry(
  collectorUrl: 'https://debug.example.test',
  appId: 'my_app',
);
AiDebug.telemetryEmit(kind: 'sync.ready', payload: {'items': 3});
await AiDebug.telemetryFlush();
await AiDebug.stopTelemetry();
```

## Connect locally

Open `http://127.0.0.1:9999/dashboard`, enter the token, or point an MCP client
at `http://127.0.0.1:9999/mcp`. REST clients use either bearer auth or the
`X-AI-Debug-Token` header.

```bash
curl -H "Authorization: Bearer $AI_DEBUG_TOKEN" \
  http://127.0.0.1:9999/api/tools
```

An Android emulator or device has its own loopback interface. A USB transport
can expose the in-app server without granting LAN access:

```bash
adb forward tcp:9999 tcp:9999
```

The forward is transport only; UI inspection and actions still use ai_debug
tools. Remove it with `adb forward --remove tcp:9999` when finished.

## Stop

```dart
await AiDebug.dispose();
```

Dispose closes HTTP and mDNS, waits for a running serialized tool handler to
settle, restores owned Flutter controls, stops monitors, and releases
app-process resources. App registrations have explicit clear or unregister
methods when they should not survive a later restart.
