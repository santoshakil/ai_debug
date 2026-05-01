import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'builtins/builtins.dart';
import 'builtins/navigation_tools.dart' show setNavigatorStateKey;
import 'builtins/screenshot_tool.dart' show setScreenshotRootKey;
import 'builtins/state_inspector_tools.dart' show stateInspectors;
import 'internal/bridge.dart';
import 'internal/telemetry.dart';
import 'registry.dart';

/// Public entry point for the ai_debug package.
///
/// Start the bridge once at app boot (any time is fine — the native Rust
/// server starts asynchronously and blocks on nothing):
///
/// ```dart
/// if (kDebugMode) {
///   await AiDebug.start(appId: 'my_app');
/// }
/// ```
///
/// Then register your app-specific tools anywhere via [register] /
/// [registerGroup] / [registerStateInspector]. Built-in tools (widget_tree,
/// screenshot, device_info, clipboard, etc.) are installed automatically.
class AiDebug {
  AiDebug._();

  /// Whether [start] has been called and the native server is up.
  static bool get isStarted => Bridge.I.isStarted;

  /// Host the embedded server is bound on (populated after [start]).
  static String? get endpointHost => Bridge.I.endpointHost;

  /// Port the embedded server is bound on (populated after [start]).
  static int? get endpointPort => Bridge.I.endpointPort;

  /// Start the native server. Idempotent — subsequent calls are no-ops.
  ///
  /// Built-in tools are registered automatically as part of start-up.
  static Future<void> start({required String appId, int port = 9999}) async {
    final fresh = !Bridge.I.isStarted;
    await Bridge.I.start(appId: appId, port: port);
    if (fresh) {
      registerAllBuiltinTools(Bridge.I.registry);
      // Broadcast built-in registrations to Rust now that the server is up.
      for (final e in Bridge.I.registry.all) {
        Bridge.I.registerTool(e);
      }
    }
  }

  /// Register a single tool.
  static void register({
    required String name,
    required String description,
    AiDebugSchema? inputSchema,
    required AiDebugHandler handler,
    bool streaming = false,
  }) {
    Bridge.I.registerTool(ToolEntry(
      name: name,
      description: description,
      inputSchema: inputSchema ?? AiDebugSchema.empty(),
      handler: handler,
      streaming: streaming,
    ));
  }

  /// Register a group of tools under a common prefix. The resulting tool names
  /// are `<prefix>.<key>`.
  static void registerGroup(
    String prefix,
    Map<String, ({String description, AiDebugSchema? inputSchema, AiDebugHandler handler})> entries,
  ) {
    for (final e in entries.entries) {
      register(
        name: '$prefix.${e.key}',
        description: e.value.description,
        inputSchema: e.value.inputSchema,
        handler: e.value.handler,
      );
    }
  }

  /// Unregister a tool by name.
  static void unregister(String name) => Bridge.I.unregisterTool(name);

  /// Register a state inspector — exposed through the `dump_state` tool
  /// (`dump_state { name: '<name>' }`). Use this when you want the agent to
  /// peek at your app's state without adding a separate tool per provider.
  ///
  /// ```dart
  /// AiDebug.registerStateInspector('auth', () => ref.read(authProvider).toJson());
  /// ```
  static void registerStateInspector(String name, Future<Object?> Function() getter) {
    stateInspectors.add(name, getter);
  }

  /// Convenience for synchronous inspectors — accepts a sync getter.
  static void registerStateInspectorSync(String name, Object? Function() getter) {
    stateInspectors.add(name, () async => getter());
  }

  static void unregisterStateInspector(String name) => stateInspectors.remove(name);

  /// Register a GlobalKey that wraps the app in a RepaintBoundary, enabling
  /// the built-in `screenshot` tool in release builds.
  ///
  /// ```dart
  /// final rootKey = GlobalKey();
  /// AiDebug.setScreenshotRoot(rootKey);
  /// runApp(RepaintBoundary(key: rootKey, child: MyApp()));
  /// ```
  static void setScreenshotRoot(GlobalKey? key) => setScreenshotRootKey(key);

  /// Register the root [NavigatorState] key so navigator tools work:
  ///
  /// ```dart
  /// final navKey = GlobalKey<NavigatorState>();
  /// AiDebug.setNavigatorKey(navKey);
  /// runApp(MaterialApp(navigatorKey: navKey, ...));
  /// ```
  static void setNavigatorKey(GlobalKey<NavigatorState>? key) => setNavigatorStateKey(key);

  /// Read the in-memory Dart log buffer directly (primarily for tests/devtools).
  static Iterable<LogRecord> tailLogs({int limit = 200}) =>
      Bridge.I.logs.tail(limit: limit);

  /// Start the telemetry pusher. POSTs Logger.root warnings + AI_DEBUG_BG markers
  /// + lifecycle transitions to a remote collector. Call from foreground AND
  /// background isolates with distinct `isolate` names so events are
  /// distinguishable on the server side.
  ///
  /// ```dart
  /// AiDebug.startTelemetry(
  ///   collectorUrl: 'http://<collector-host>:9990',
  ///   appId: 'my_app',
  ///   isolate: 'main',
  /// );
  /// ```
  static void startTelemetry({
    required String collectorUrl,
    required String appId,
    String isolate = 'main',
  }) {
    Telemetry.I.start(collectorUrl: collectorUrl, appId: appId, isolate: isolate);
  }

  /// Stop the telemetry pusher.
  static void stopTelemetry() => Telemetry.I.stop();

  /// Manually emit a telemetry event (kind + payload).
  static void telemetryEmit({required String kind, Map<String, dynamic>? payload}) =>
      Telemetry.I.emit(kind: kind, payload: payload);

  /// Force-flush queued telemetry events.
  static Future<void> telemetryFlush() => Telemetry.I.flushNow();

  /// Whether telemetry is enabled.
  static bool get telemetryEnabled => Telemetry.I.isEnabled;

  /// Shut down. Normally not needed — app termination is fine.
  static Future<void> dispose() => Bridge.I.dispose();
}
