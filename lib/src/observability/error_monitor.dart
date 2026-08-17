import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';

class ErrorMonitor {
  ErrorMonitor({this.capacity = 500}) {
    if (capacity < 1) {
      throw RangeError.range(capacity, 1, null, 'capacity');
    }
  }

  final int capacity;
  final Queue<ErrorEvent> _events = Queue();
  FlutterExceptionHandler? _previousFlutter;
  FlutterExceptionHandler? _flutterHandler;
  ErrorCallback? _previousPlatform;
  ErrorCallback? _platformHandler;
  Object? _generation;
  var _sequence = 0;
  var _dropped = 0;
  var _started = false;

  bool get isStarted => _started;
  int get dropped => _dropped;
  int get length => _events.length;

  void start() {
    if (_started) return;
    _started = true;
    final generation = Object();
    _generation = generation;
    final previousFlutter = FlutterError.onError;
    _previousFlutter = previousFlutter;
    _flutterHandler = (details) {
      if (identical(_generation, generation)) {
        try {
          record(
            details.exception,
            details.stack ?? StackTrace.current,
            source: 'flutter',
            context: details.context?.toDescription(),
          );
        } catch (_) {}
      }
      previousFlutter?.call(details);
    };
    FlutterError.onError = _flutterHandler;

    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    _previousPlatform = previousPlatform;
    _platformHandler = (error, stack) {
      if (identical(_generation, generation)) {
        try {
          record(error, stack, source: 'platform');
        } catch (_) {}
      }
      return previousPlatform?.call(error, stack) ?? false;
    };
    dispatcher.onError = _platformHandler;
  }

  void record(
    Object error,
    StackTrace stack, {
    String source = 'app',
    String? context,
  }) {
    _events.add(
      ErrorEvent(
        sequence: ++_sequence,
        timestamp: DateTime.now(),
        source: _cut(source, 256),
        error: _text(error, 16384),
        stack: _text(stack, 32768),
        context: context == null ? null : _cut(context, 4096),
      ),
    );
    while (_events.length > capacity) {
      _events.removeFirst();
      _dropped++;
    }
  }

  List<ErrorEvent> history({int? after, int limit = 100}) {
    if (limit < 1) {
      throw RangeError.range(limit, 1, null, 'limit');
    }
    return [
      for (final event in _events)
        if (after == null || event.sequence > after) event,
    ].reversed.take(limit).toList(growable: false).reversed.toList();
  }

  void clear() {
    _events.clear();
    _dropped = 0;
  }

  void dispose() {
    if (_started) {
      if (identical(FlutterError.onError, _flutterHandler)) {
        FlutterError.onError = _previousFlutter;
      }
      final dispatcher = PlatformDispatcher.instance;
      if (identical(dispatcher.onError, _platformHandler)) {
        dispatcher.onError = _previousPlatform;
      }
    }
    _previousFlutter = null;
    _flutterHandler = null;
    _previousPlatform = null;
    _platformHandler = null;
    _generation = null;
    _started = false;
    clear();
  }
}

class ErrorEvent {
  final int sequence;
  final DateTime timestamp;
  final String source;
  final String error;
  final String stack;
  final String? context;

  const ErrorEvent({
    required this.sequence,
    required this.timestamp,
    required this.source,
    required this.error,
    required this.stack,
    this.context,
  });

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'timestamp': timestamp.toIso8601String(),
    'timestampMs': timestamp.millisecondsSinceEpoch,
    'source': source,
    'error': error,
    'stack': stack,
    if (context != null) 'context': context,
  };
}

String _cut(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

String _text(Object value, int max) {
  try {
    return _cut(value.toString(), max);
  } catch (_) {
    return '<unavailable>';
  }
}
