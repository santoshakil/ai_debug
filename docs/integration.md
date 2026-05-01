# Integrating ai_debug into a Flutter app

Three additions to your app:

1. `pubspec.yaml`:
   ```yaml
   dependencies:
     ai_debug:
       git:
         url: https://github.com/santoshakil/ai_debug.git
         path: flutter/packages/ai_debug
   ```
   For local development against a checked-out copy:
   ```yaml
   dependencies:
     ai_debug:
       path: /abs/path/to/ai_debug/flutter/packages/ai_debug
   ```

2. `main.dart`:
   ```dart
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

3. Anywhere, register custom tools:
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

The HTTP server listens on `:9999` by default. Built-in tools (logs, time, network, runtime, channel invoke, telemetry) are registered automatically by `AiDebug.start()`.

## Loading the dylib during development

The Dart package opens the dylib by searching, in this order:

1. Symbols already in the current process (Flutter release/profile builds embed it via native assets).
2. `AI_DEBUG_DYLIB=/abs/path/to/libai_debug.dylib` environment variable.
3. Default filename per platform (`libai_debug.dylib`, `libai_debug.so`, `ai_debug.dll`) — must be on the loader search path.

### macOS desktop

```bash
cargo build -p ai_debug
DYLIB_DIR=$(cargo metadata --format-version=1 \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])")/debug
AI_DEBUG_DYLIB="$DYLIB_DIR/libai_debug.dylib" flutter run -d macos
```

### iOS device / simulator

The package uses `native_toolchain_rust` to drive `cargo build` as part of the Flutter native-assets pipeline. No manual linking required for normal `flutter run` flows once the package is in `pubspec.yaml`.

For pre-existing apps that haven't migrated to native assets, link the static library `libai_debug.a` into the Runner target manually, or package the dylib into the Flutter framework.

### Android

`native_toolchain_rust` cross-compiles via the Android NDK and bundles the resulting `libai_debug.so` for the configured ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) automatically. Make sure `ANDROID_NDK_HOME` (or `ANDROID_NDK_ROOT`) points at a recent NDK in the same Flutter shell.

For host access during development, the bridge listens on `0.0.0.0:9999` inside the app sandbox — reach it from the host with `adb forward`:

```bash
adb forward tcp:19999 tcp:9999
curl http://localhost:19999/healthz   # → ok
```

If you need it from another LAN host (a teammate's laptop, an MCP client running off-device), point that machine at the device's WiFi IP directly: `http://<device-wifi-ip>:9999/...`.

For manual placement when not using native assets: copy the `.so` into `android/app/src/main/jniLibs/<abi>/`.

## Background isolate setup

If your app uses background isolates (e.g., a separate Flutter engine for `WorkManager` / `BGTaskScheduler` work), call `AiDebug.start()` in the background entrypoint too. Use a distinct `appId` suffix or `isolate` label so events don't get conflated:

```dart
@pragma('vm:entry-point')
void backgroundEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AiDebug.start(appId: 'my_app');
  AiDebug.startTelemetry(
    collectorUrl: 'http://<collector-host>:9990',
    appId: 'my_app',
    isolate: 'bg',
  );
  // ... your background work
}
```

Note: on iOS, the bridge HTTP server **cannot be bound twice** to the same port. If main + background isolates both call `AiDebug.start()` while both are alive, the second one fails to bind and only the first one will respond to `curl`. The collector path (push-based, opens a fresh socket per event) is the right way to observe both isolates simultaneously.

## What's exposed

- `GET /healthz` → plaintext `ok`
- `GET /api/tools` → list of registered tools (shape compatible with MCP `tools/list`)
- `GET /api/logs?limit=&level=&grep=&source=&since_ms=` → merged log tail (Rust tracing + Dart Logger)
- `POST /api/cmd/:name` → invoke a Dart tool with JSON body args
- `GET|HEAD /api/file?path=<abs>` → stream a file off the device (Range supported, kernel→socket)
- `POST /mcp` → MCP JSON-RPC (Streamable HTTP, MCP 2025-03-26)
