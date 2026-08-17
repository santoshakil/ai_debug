import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'builtins/builtins.dart';
import 'automation/models.dart';
import 'builtins/automation_tools.dart' show disposeAutomationTools;
import 'builtins/devtools_tools.dart'
    show devToolsRuntime, disposeDevToolsTools;
import 'builtins/diagnostics_tools.dart' show disposeDiagnosticsTools;
import 'builtins/navigation_tools.dart'
    show clearNavigationAdapter, setNavigationAdapter;
import 'builtins/network_monitor_tools.dart'
    show disposeNetworkMonitorTools, networkMonitor;
import 'builtins/observer_tools.dart' show disposeObserverTools;
import 'builtins/error_monitor_tools.dart'
    show disposeErrorMonitorTools, errorMonitor;
import 'builtins/isolate_tools.dart' show disposeIsolateTools, isolateHub;
import 'builtins/log_tools.dart' show disposeLogTools;
import 'builtins/screenshot_tool.dart'
    show clearScreenshotRootKey, setScreenshotRootKey;
import 'builtins/runtime_tools.dart' show disposeRuntimeTools;
import 'builtins/state_inspector_tools.dart'
    show
        addStateInspectorSource,
        clearStateInspectorSources,
        disposeStateInspectors,
        removeStateInspectorSource;
import 'builtins/time_tools.dart' show disposeTimeTools;
import 'config.dart';
import 'devtools/trace_recorder.dart';
import 'discovery/mdns.dart';
import 'internal/bridge.dart';
import 'internal/telemetry.dart';
import 'isolates/isolate_hub.dart';
import 'log_buffer.dart';
import 'navigation/navigation_adapter.dart';
import 'registry.dart';
import 'observability/network_monitor.dart';
import 'state/state_registry.dart';
import 'vm_service/vm_service_client.dart';

class AiDebug {
  AiDebug._();

  static AiDebugConfig? _activeConfig;
  static Future<void>? _starting;
  static Future<void>? _disposing;
  static final _customTools = CommandRegistry(
    reservedNames: const {'list_apps', 'tail_logs'},
  );

  static bool get isStarted => Bridge.I.isStarted;
  static String? get endpointHost => Bridge.I.endpointHost;
  static int? get endpointPort => Bridge.I.endpointPort;
  static String? get token => _activeConfig?.token;

  static Future<void> start({
    AiDebugConfig? config,
    String? appId,
    int port = 9999,
    String bindHost = '127.0.0.1',
    String? token,
    Set<String> allowedHosts = const {},
    Set<String> allowedOrigins = const {},
    Set<String> allowedFileRoots = const {},
    bool unsafeLan = false,
    bool allowRelease = false,
    Duration bodyTimeout = const Duration(seconds: 5),
    Duration toolTimeout = const Duration(seconds: 30),
    Duration shutdownTimeout = const Duration(seconds: 5),
    int maxBodyBytes = 1024 * 1024,
    int maxResultBytes = 4 * 1024 * 1024,
    int maxQueuedTools = 32,
    UiAutomationConfig automation = const UiAutomationConfig(),
    AiDebugFeatures features = const AiDebugFeatures(),
  }) async {
    final activeDispose = _disposing;
    if (activeDispose != null) await activeDispose;
    if (config != null &&
        (appId != null ||
            port != 9999 ||
            bindHost != '127.0.0.1' ||
            token != null ||
            allowedHosts.isNotEmpty ||
            allowedOrigins.isNotEmpty ||
            allowedFileRoots.isNotEmpty ||
            unsafeLan ||
            allowRelease ||
            bodyTimeout != const Duration(seconds: 5) ||
            toolTimeout != const Duration(seconds: 30) ||
            shutdownTimeout != const Duration(seconds: 5) ||
            maxBodyBytes != 1024 * 1024 ||
            maxResultBytes != 4 * 1024 * 1024 ||
            maxQueuedTools != 32 ||
            !automation.sameAs(const UiAutomationConfig()) ||
            !features.sameAs(const AiDebugFeatures()))) {
      throw ArgumentError('pass config or shorthand settings, not both');
    }
    final cfg =
        config ??
        AiDebugConfig(
          appId: appId ?? (throw ArgumentError.notNull('config or appId')),
          port: port,
          bindHost: bindHost,
          token: token ?? _activeConfig?.token,
          allowedHosts: allowedHosts,
          allowedOrigins: allowedOrigins,
          allowedFileRoots: allowedFileRoots,
          unsafeLan: unsafeLan,
          allowRelease: allowRelease,
          bodyTimeout: bodyTimeout,
          toolTimeout: toolTimeout,
          shutdownTimeout: shutdownTimeout,
          maxBodyBytes: maxBodyBytes,
          maxResultBytes: maxResultBytes,
          maxQueuedTools: maxQueuedTools,
          automation: automation,
          features: features,
        );
    cfg.validate();
    if (kReleaseMode && !cfg.allowRelease) {
      throw StateError('ai_debug is disabled in release builds');
    }
    final activeConfig = _activeConfig;
    if (activeConfig != null && !activeConfig.sameAs(cfg)) {
      throw StateError('ai_debug is already starting or started differently');
    }
    final activeStart = _starting;
    if (activeStart != null) {
      await activeStart;
      return;
    }
    if (Bridge.I.isStarted) return;
    _activeConfig = cfg;
    late final Future<void> start;
    start = _start(cfg);
    _starting = start;
    try {
      await start;
    } finally {
      if (identical(_starting, start)) _starting = null;
    }
  }

  static Future<void> _start(AiDebugConfig cfg) async {
    final fresh = !Bridge.I.isStarted;
    try {
      if (fresh) {
        registerAllBuiltinTools(Bridge.I.registry, cfg);
        for (final entry in _customTools.all) {
          Bridge.I.registerTool(entry);
        }
      }
      await Bridge.I.start(
        appId: cfg.appId,
        port: cfg.port,
        bindHost: cfg.bindHost,
        token: cfg.token,
        allowedHosts: cfg.allowedHosts,
        allowedOrigins: cfg.allowedOrigins,
        allowedFileRoots: cfg.features.files
            ? cfg.allowedFileRoots
            : const <String>{},
        unsafeLan: cfg.unsafeLan,
        bodyTimeout: cfg.bodyTimeout,
        toolTimeout: cfg.toolTimeout,
        shutdownTimeout: cfg.shutdownTimeout,
        maxBodyBytes: cfg.maxBodyBytes,
        maxResultBytes: cfg.maxResultBytes,
        maxQueuedTools: cfg.maxQueuedTools,
        logsEnabled: cfg.features.logs,
      );
      if (cfg.features.discovery) {
        final address = InternetAddress.tryParse(Bridge.I.endpointHost ?? '');
        if (address == null || address.isLoopback) {
          throw StateError('discovery requires a non-loopback bind address');
        }
        await MdnsAdvertiser.instance.start(
          appId: cfg.appId,
          port: Bridge.I.endpointPort!,
          address: address,
        );
      }
    } catch (_) {
      if (fresh) await _disposeParts();
      rethrow;
    }
  }

  static void register({
    required String name,
    required String description,
    String? title,
    AiDebugSchema? inputSchema,
    AiDebugSchema? outputSchema,
    Map<String, Object?>? annotations,
    required AiDebugHandler handler,
  }) {
    _assertRegistrationOpen();
    _customTools.register(
      ToolEntry(
        name: name,
        description: description,
        title: title,
        inputSchema: inputSchema ?? AiDebugSchema.empty(),
        outputSchema: outputSchema,
        annotations: annotations,
        handler: handler,
      ),
    );
  }

  static void registerGroup(
    String prefix,
    Map<
      String,
      ({String description, AiDebugSchema? inputSchema, AiDebugHandler handler})
    >
    entries,
  ) {
    _assertRegistrationOpen();
    final added = <String>[];
    try {
      for (final e in entries.entries) {
        final name = '$prefix.${e.key}';
        _customTools.register(
          ToolEntry(
            name: name,
            description: e.value.description,
            inputSchema: e.value.inputSchema ?? AiDebugSchema.empty(),
            handler: e.value.handler,
          ),
        );
        added.add(name);
      }
    } catch (_) {
      for (final name in added) {
        _customTools.remove(name);
      }
      rethrow;
    }
  }

  static bool unregister(String name) {
    _assertRegistrationOpen();
    return _customTools.remove(name);
  }

  static void clearRegisteredTools() {
    _assertRegistrationOpen();
    _customTools.clear();
  }

  static void _assertRegistrationOpen() {
    if (_activeConfig != null ||
        _starting != null ||
        _disposing != null ||
        Bridge.I.isStarted) {
      throw StateError('register app tools before starting ai_debug');
    }
  }

  static NetworkRequest trackNetwork({
    required String method,
    required Uri uri,
    int? requestBytes,
    String? client,
  }) => networkMonitor.start(
    method: method,
    uri: uri,
    requestBytes: requestBytes,
    client: client,
  );

  static void recordError(
    Object error,
    StackTrace stack, {
    String source = 'app',
    String? context,
  }) {
    errorMonitor.record(error, stack, source: source, context: context);
  }

  static void startTracing({bool clear = false}) =>
      devToolsRuntime.trace.start(clear: clear);

  static void stopTracing() => devToolsRuntime.stopTrace();

  static TraceSpan? startTrace(
    String name, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) => devToolsRuntime.trace.startSpan(
    name,
    category: category,
    arguments: arguments,
  );

  static void traceInstant(
    String name, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) => devToolsRuntime.trace.instant(
    name,
    category: category,
    arguments: arguments,
  );

  static T traceSync<T>(
    String name,
    T Function() action, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) => devToolsRuntime.trace.timeSync(
    name,
    action,
    category: category,
    arguments: arguments,
  );

  static Future<T> traceAsync<T>(
    String name,
    FutureOr<T> Function() action, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) => devToolsRuntime.trace.timeAsync(
    name,
    action,
    category: category,
    arguments: arguments,
  );

  static R? runGuarded<R>(
    R Function() body, {
    void Function(Object error, StackTrace stack)? onError,
  }) => runZonedGuarded(body, (error, stack) {
    recordError(error, stack, source: 'zone');
    onError?.call(error, stack);
  });

  static void registerStateSource(StateSource source) {
    addStateInspectorSource(source);
  }

  static void registerStateInspector(
    String name,
    Future<Object?> Function() getter,
  ) {
    registerStateSource(StateSource(name: name, snapshot: getter));
  }

  static void registerStateInspectorSync(
    String name,
    Object? Function() getter,
  ) {
    registerStateSource(StateSource(name: name, snapshot: getter));
  }

  static Future<bool> unregisterStateInspector(String name) =>
      removeStateInspectorSource(name);

  static Future<void> clearStateInspectors() => clearStateInspectorSources();

  static SendPort get isolatePort => isolateHub.sendPort;

  static AiDebugIsolateClient attachIsolate(
    SendPort hub, {
    required String name,
    Duration heartbeat = const Duration(seconds: 5),
  }) => AiDebugIsolateClient.attach(hub, name: name, heartbeat: heartbeat);

  static void setScreenshotRoot(GlobalKey? key) => setScreenshotRootKey(key);

  static void clearScreenshotRoot() => clearScreenshotRootKey();

  static void setNavigation(NavigationAdapter? adapter) =>
      setNavigationAdapter(adapter);

  static void clearNavigation() => clearNavigationAdapter();

  static Iterable<AiDebugLogRecord> tailLogs({int limit = 200}) =>
      Bridge.I.logs.tail(limit: limit);

  static void startTelemetry({
    required String collectorUrl,
    required String appId,
    String isolate = 'main',
  }) {
    _requireTelemetry();
    Telemetry.I.start(
      collectorUrl: collectorUrl,
      appId: appId,
      isolate: isolate,
    );
  }

  static Future<void> stopTelemetry() => Telemetry.I.stop();

  static void telemetryEmit({
    required String kind,
    Map<String, dynamic>? payload,
  }) {
    _requireTelemetry();
    Telemetry.I.emit(kind: kind, payload: payload);
  }

  static Future<void> telemetryFlush() {
    _requireTelemetry();
    return Telemetry.I.flushNow();
  }

  static bool get telemetryEnabled => Telemetry.I.isEnabled;

  static void _requireTelemetry() {
    final config = _activeConfig;
    if (config == null || !Bridge.I.isStarted) {
      throw StateError('start ai_debug before using telemetry');
    }
    if (!config.features.telemetry) {
      throw StateError('telemetry feature is disabled');
    }
  }

  static Future<void> dispose() {
    final active = _disposing;
    if (active != null) return active;
    final future = _dispose();
    _disposing = future;
    return future.whenComplete(() {
      if (identical(_disposing, future)) _disposing = null;
    });
  }

  static Future<void> _dispose() async {
    try {
      await _starting;
    } catch (_) {}
    await _disposeParts();
  }

  static Future<void> _disposeParts() async {
    Object? error;
    StackTrace? stack;
    var reassemble = false;
    Future<void> run(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (nextError, nextStack) {
        error ??= nextError;
        stack ??= nextStack;
      }
    }

    await run(Bridge.I.dispose);
    await run(stopTelemetry);
    await run(MdnsAdvertiser.instance.stop);
    await run(VmServiceClient.instance.dispose);
    await run(() => disposeObserverTools());
    await run(() => disposeErrorMonitorTools());
    await run(() => disposeNetworkMonitorTools());
    await run(() => reassemble |= disposeDiagnosticsTools());
    await run(() => disposeLogTools());
    await run(() => reassemble |= disposeRuntimeTools());
    await run(() => disposeTimeTools());
    await run(disposeAutomationTools);
    await run(disposeDevToolsTools);
    await run(disposeIsolateTools);
    await run(disposeStateInspectors);
    if (reassemble) {
      await run(WidgetsBinding.instance.reassembleApplication);
    }
    _activeConfig = null;
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }
}
