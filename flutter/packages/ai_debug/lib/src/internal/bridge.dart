import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

import '../ffi_bindings.dart' as bindings;
import '../generated/ai_debug.pb.dart' as pb;
import '../log_buffer.dart';
import '../native_events.dart';
import '../registry.dart';
import 'level_codec.dart';

/// Core plumbing behind the `AiDebug` facade.
///
/// Responsibilities:
///   * Own the single [NativeEventReceiver] + [DartLogBuffer].
///   * Dispatch incoming `ToDart` envelopes (tool invocations + log queries)
///     to the registered [CommandRegistry].
///   * Send `ToRust` envelopes (tool registration, tool results).
///
/// Package-private to the ai_debug library (no `_` so builtin files can touch
/// it, but don't expose it from `package:ai_debug/ai_debug.dart`).
class Bridge {
  Bridge._();

  static final Bridge I = Bridge._();

  final CommandRegistry registry = CommandRegistry();
  final DartLogBuffer logs = DartLogBuffer();
  final Logger _logger = Logger('AiDebug');

  NativeEventReceiver? _rx;
  StreamSubscription? _rxSub;
  StreamSubscription<LogRecord>? _logSub;
  bool _started = false;

  String? endpointHost;
  int? endpointPort;

  bool get isStarted => _started;

  /// Start the server. Idempotent.
  Future<void> start({required String appId, int port = 9999}) async {
    if (_started) return;
    _started = true;

    Logger.root.level = Level.ALL;
    _logSub = Logger.root.onRecord.listen(logs.push);

    _rx = NativeEventReceiver();
    _rxSub = _rx!.events.listen(_onNativeEvent);

    final configJson = jsonEncode({'appId': appId, 'port': port});
    final configBytes = utf8.encode(configJson);
    final buf = _withBytes(configBytes, (ptr, len) {
      return bindings.ai_debug_init(_rx!.dartApiData, _rx!.nativePortId, ptr, len);
    });

    final initJson = _readBufferAsJson(buf);
    if (initJson['ok'] == true) {
      endpointHost = initJson['host'] as String?;
      endpointPort = initJson['port'] as int?;
      _logger.info('ai_debug listening on $endpointHost:$endpointPort');
    } else {
      _logger.severe('ai_debug init failed: ${initJson['error']}');
    }
  }

  /// Register a tool locally + push the registration to Rust so it shows up
  /// in `/api/tools` and MCP `tools/list`.
  void registerTool(ToolEntry entry) {
    registry.add(entry);
    final env = pb.ToRust()
      ..register = (pb.RegisterTool()
        ..name = entry.name
        ..description = entry.description
        ..inputSchemaJson = jsonEncode(entry.inputSchema.asJson)
        ..streaming = entry.streaming);
    _sendEnvelope(env);
  }

  /// Unregister a previously-registered tool.
  void unregisterTool(String name) {
    if (registry.remove(name)) {
      final env = pb.ToRust()..unregister = (pb.UnregisterTool()..name = name);
      _sendEnvelope(env);
    }
  }

  Future<void> dispose() async {
    if (!_started) return;
    _started = false;
    bindings.ai_debug_shutdown();
    await _logSub?.cancel();
    _logSub = null;
    await _rxSub?.cancel();
    _rxSub = null;
    _rx?.dispose();
    _rx = null;
  }

  // ---- native event handlers -----------------------------------------------

  void _onNativeEvent(NativeEnvelope env) {
    switch (env.id) {
      case NativeEventId.envelope:
        _handleToDart(env.bytes);
    }
  }

  void _handleToDart(Uint8List bytes) {
    final pb.ToDart msg;
    try {
      msg = pb.ToDart.fromBuffer(bytes);
    } catch (e, st) {
      _logger.warning('decode ToDart failed', e, st);
      return;
    }

    if (msg.hasInvoke()) {
      unawaited(_dispatchInvoke(msg.invoke));
      return;
    }
    if (msg.hasQueryDartLogs()) {
      _respondDartLogs(msg.queryDartLogs);
      return;
    }
  }

  Future<void> _dispatchInvoke(pb.ToolInvoke inv) async {
    final args = inv.argsJson.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(inv.argsJson) as Map<String, dynamic>);

    final result = pb.ToolResult()..requestId = inv.requestId;
    try {
      final res = await registry.dispatch(inv.name, args);
      result
        ..success = true
        ..resultJson = jsonEncode(res.json);
      if (res.binary != null) {
        result
          ..binary = res.binary!
          ..binaryMime = res.binaryMime ?? 'application/octet-stream';
      }
    } catch (e, st) {
      _logger.warning('tool "${inv.name}" failed', e, st);
      result
        ..success = false
        ..error = e.toString();
    }
    _sendEnvelope(pb.ToRust()..toolResult = result);
  }

  void _respondDartLogs(pb.QueryDartLogs q) {
    final minLvl = q.hasMinLevel() ? pbLevelToLoggingLevel(q.minLevel) : null;
    final records = logs
        .tail(
          limit: q.limit == 0 ? 200 : q.limit,
          minLevel: minLvl,
          grep: q.hasGrep() ? q.grep : null,
          since: q.hasSinceMs()
              ? DateTime.fromMillisecondsSinceEpoch(q.sinceMs.toInt())
              : null,
        )
        .toList();

    final payload = records
        .map((r) => {
              'timestamp_ms': r.time.millisecondsSinceEpoch,
              'source': 'dart',
              'level': loggingLevelToStr(r.level),
              'logger': r.loggerName,
              'message': r.message,
              if (r.error != null) 'error': r.error.toString(),
              if (r.stackTrace != null) 'stack': r.stackTrace.toString(),
            })
        .toList();

    _sendEnvelope(pb.ToRust()
      ..toolResult = (pb.ToolResult()
        ..requestId = q.requestId
        ..success = true
        ..resultJson = jsonEncode({'logs': payload})));
  }

  // ---- FFI send helpers ----------------------------------------------------

  void _sendEnvelope(pb.ToRust envelope) {
    final bytes = envelope.writeToBuffer();
    if (bytes.isEmpty) return;
    _withBytes(bytes, (ptr, len) {
      final buf = bindings.ai_debug_send(ptr, len);
      bindings.free_buffer(buf);
      return buf;
    });
  }

  bindings.ByteBuffer _withBytes(
    Uint8List bytes,
    bindings.ByteBuffer Function(ffi.Pointer<ffi.Uint8>, int) fn,
  ) {
    if (bytes.isEmpty) return fn(ffi.nullptr, 0);
    final ptr = malloc.allocate<ffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return fn(ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  Map<String, dynamic> _readBufferAsJson(bindings.ByteBuffer buf) {
    try {
      if (buf.ptr == ffi.nullptr || buf.len == 0) return const {};
      final view = buf.ptr.asTypedList(buf.len);
      final txt = utf8.decode(view);
      final obj = jsonDecode(txt);
      return obj is Map<String, dynamic> ? obj : {};
    } finally {
      bindings.free_buffer(buf);
    }
  }
}
