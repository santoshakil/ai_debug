import 'dart:async';

import 'package:logging/logging.dart';

import '../log_buffer.dart';
import '../registry.dart';
import 'server.dart';

class Bridge {
  Bridge._();

  static final Bridge I = Bridge._();

  final CommandRegistry registry = CommandRegistry(
    reservedNames: const {'list_apps', 'tail_logs'},
  );
  final DartLogBuffer logs = DartLogBuffer();
  final Logger _logger = Logger('AiDebug');
  late final Server _server = Server(registry: registry, logs: logs);

  StreamSubscription<LogRecord>? _logSub;
  bool _started = false;
  Future<void>? _starting;
  Future<void>? _disposing;

  String? endpointHost;
  int? endpointPort;

  bool get isStarted => _started;

  Future<void> start({
    required String appId,
    int port = 9999,
    String bindHost = '127.0.0.1',
    required String token,
    Set<String> allowedHosts = const {},
    Set<String> allowedOrigins = const {},
    Set<String> allowedFileRoots = const {},
    bool unsafeLan = false,
    Duration bodyTimeout = const Duration(seconds: 5),
    Duration toolTimeout = const Duration(seconds: 30),
    Duration shutdownTimeout = const Duration(seconds: 5),
    int maxBodyBytes = 1024 * 1024,
    int maxResultBytes = 4 * 1024 * 1024,
    int maxQueuedTools = 32,
    bool logsEnabled = true,
  }) async {
    await _disposing;
    final config = ServerConfig(
      appId: appId,
      bindHost: bindHost,
      port: port,
      token: token,
      allowedHosts: allowedHosts,
      allowedOrigins: allowedOrigins,
      allowedFileRoots: allowedFileRoots,
      unsafeLan: unsafeLan,
      bodyTimeout: bodyTimeout,
      toolTimeout: toolTimeout,
      shutdownTimeout: shutdownTimeout,
      maxBodyBytes: maxBodyBytes,
      maxResultBytes: maxResultBytes,
      maxQueuedTools: maxQueuedTools,
      logsEnabled: logsEnabled,
    );
    final active = _starting;
    if (active != null) {
      await _server.start(config);
      await active;
      return;
    }

    late final Future<void> future;
    future = _start(config);
    _starting = future;
    try {
      await future;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  Future<void> _start(ServerConfig config) async {
    if (_started) {
      await _server.start(config);
      return;
    }
    if (config.logsEnabled) {
      _logSub = Logger.root.onRecord.listen(logs.push);
    }

    try {
      final addr = await _server.start(config);
      endpointHost = addr.host;
      endpointPort = addr.port;
      _started = true;
      _logger.info('ai_debug listening on ${addr.host}:${addr.port}');
    } catch (e, st) {
      await _logSub?.cancel();
      _logSub = null;
      _logger.severe(
        'ai_debug failed to bind on ${config.bindHost}:${config.port}',
        e,
        st,
      );
      rethrow;
    }
  }

  void registerTool(ToolEntry entry) {
    registry.register(entry);
  }

  void unregisterTool(String name) {
    registry.remove(name);
  }

  Future<void> dispose() {
    final active = _disposing;
    if (active != null) return active;
    final future = _dispose();
    _disposing = future;
    return future.whenComplete(() {
      if (identical(_disposing, future)) _disposing = null;
    });
  }

  Future<void> _dispose() async {
    try {
      await _starting;
    } catch (_) {}
    Object? error;
    StackTrace? stack;
    Future<void> run(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (nextError, nextStack) {
        error ??= nextError;
        stack ??= nextStack;
      }
    }

    if (_started) {
      _started = false;
      final logSub = _logSub;
      _logSub = null;
      if (logSub != null) await run(logSub.cancel);
      await run(_server.stop);
    }
    await run(() => registry.clear());
    await run(logs.clear);
    endpointHost = null;
    endpointPort = null;
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }
}
