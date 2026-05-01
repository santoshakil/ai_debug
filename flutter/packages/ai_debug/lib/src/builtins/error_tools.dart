import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../registry.dart';

/// Error injection + history. The history is a passive Logger.root subscriber
/// that classifies records by level and source, holding a circular buffer for
/// later inspection without polluting other log sinks.
class _ErrorBucket {
  final List<_ErrorEvt> events = [];
  void add(_ErrorEvt e) {
    events.add(e);
    while (events.length > 1024) {
      events.removeAt(0);
    }
  }
}

class _ErrorEvt {
  final DateTime when;
  final String level;
  final String? logger;
  final String message;
  final String? error;
  final String? stack;
  _ErrorEvt(this.when, this.level, this.logger, this.message, this.error, this.stack);
  Map<String, dynamic> toJson() => {
        'when': when.toIso8601String(),
        'whenMs': when.millisecondsSinceEpoch,
        'level': level,
        'logger': logger,
        'message': message,
        if (error != null) 'error': error,
        if (stack != null) 'stack': stack,
      };
}

final _bucket = _ErrorBucket();
StreamSubscription<LogRecord>? _sub;
FlutterExceptionHandler? _origFlutter;

void _ensureObserver() {
  _sub ??= Logger.root.onRecord.listen((r) {
    if (r.level < Level.WARNING) return;
    _bucket.add(_ErrorEvt(
      r.time,
      r.level.name.toLowerCase(),
      r.loggerName.isEmpty ? null : r.loggerName,
      r.message,
      r.error?.toString(),
      r.stackTrace?.toString(),
    ));
  });
  if (_origFlutter == null) {
    _origFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _bucket.add(_ErrorEvt(
        DateTime.now(),
        'flutter',
        details.library,
        details.exceptionAsString(),
        details.exception.toString(),
        details.stack?.toString(),
      ));
      _origFlutter?.call(details);
    };
  }
}

/// Register error injection + observation tools.
void registerErrorTools(CommandRegistry registry) {
  _ensureObserver();

  registry.add(ToolEntry(
    name: 'error_history',
    description:
        'Recent warning+severe Logger records and FlutterError.onError captures. '
        'Independent of any drift/db log sink — purely in-memory.',
    inputSchema: AiDebugSchema.object({
      'limit': AiDebugSchema.integer(default_: 100, min: 1, max: 1024),
      'minLevel': AiDebugSchema.string(
        default_: 'warning',
        enum_: ['warning', 'severe', 'shout', 'flutter'],
      ),
    }),
    handler: (args) async {
      _ensureObserver();
      final limit = (args['limit'] as num?)?.toInt() ?? 100;
      final minLevel = (args['minLevel'] as String?) ?? 'warning';
      final order = ['warning', 'severe', 'shout', 'flutter'];
      final minIdx = order.indexOf(minLevel);
      final filtered = _bucket.events
          .where((e) => order.indexOf(e.level) >= (minIdx < 0 ? 0 : minIdx))
          .toList();
      final tail = filtered.length > limit
          ? filtered.sublist(filtered.length - limit)
          : filtered;
      return {
        'count': tail.length,
        'totalCaptured': _bucket.events.length,
        'errors': tail.map((e) => e.toJson()).toList(),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'error_clear_history',
    description: 'Clear the in-memory error history.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      _bucket.events.clear();
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'error_throw',
    description:
        'Throw a synchronous exception inside the handler — verifies that the bridge '
        'serializes errors back over the wire correctly. Returns nothing on success (it never returns).',
    inputSchema: AiDebugSchema.object({
      'message': AiDebugSchema.string(default_: 'ai_debug test exception'),
    }),
    handler: (args) async {
      throw Exception((args['message'] as String?) ?? 'ai_debug test exception');
    },
  ));

  registry.add(ToolEntry(
    name: 'error_throw_async',
    description:
        'Throw an async exception (after a short delay). Useful to test post-await error '
        'propagation through ai_debug. Pair with error_history to verify capture.',
    inputSchema: AiDebugSchema.object({
      'message': AiDebugSchema.string(default_: 'ai_debug async test'),
      'delayMs': AiDebugSchema.integer(default_: 0, min: 0, max: 5000),
    }),
    handler: (args) async {
      final delayMs = (args['delayMs'] as num?)?.toInt() ?? 0;
      if (delayMs > 0) await Future.delayed(Duration(milliseconds: delayMs));
      throw Exception((args['message'] as String?) ?? 'ai_debug async test');
    },
  ));

  registry.add(ToolEntry(
    name: 'error_assert_fail',
    description:
        'Trigger a Dart `assert(false, ...)` — only effective in debug builds. '
        'In release builds returns ok=true with note=skipped.',
    inputSchema: AiDebugSchema.object({
      'message': AiDebugSchema.string(default_: 'ai_debug assert test'),
    }),
    handler: (args) async {
      assert(false, args['message'] as String? ?? 'ai_debug assert test');
      return {'ok': true, 'note': 'skipped — assert is no-op in release builds'};
    },
  ));

  registry.add(ToolEntry(
    name: 'error_log_warning',
    description:
        'Emit a warning-level Logger record under name `ai_debug.test`. '
        'Use to confirm Logger.root piping is working without crashing the app.',
    inputSchema: AiDebugSchema.object({
      'message': AiDebugSchema.string(default_: 'ai_debug warn test'),
    }),
    handler: (args) async {
      Logger('ai_debug.test').warning(args['message'] as String? ?? 'ai_debug warn test');
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'error_log_severe',
    description: 'Emit a severe-level Logger record. Logged into ai_debug error_history.',
    inputSchema: AiDebugSchema.object({
      'message': AiDebugSchema.string(default_: 'ai_debug severe test'),
    }),
    handler: (args) async {
      Logger('ai_debug.test').severe(args['message'] as String? ?? 'ai_debug severe test');
      return {'ok': true};
    },
  ));
}
