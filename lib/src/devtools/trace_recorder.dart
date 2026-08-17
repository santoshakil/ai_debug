import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'bounded_buffer.dart';
import 'resource_monitor.dart' show WallClock;

typedef TraceClock = int Function();

class TraceEvent {
  const TraceEvent({
    required this.sequence,
    required this.name,
    required this.category,
    required this.phase,
    required this.startedAtMicros,
    required this.durationMicros,
    required this.wallTime,
    required this.processId,
    required this.timelineLaneId,
    required this.isolateName,
    required this.isolateId,
    required this.arguments,
  });

  final int sequence;
  final String name;
  final String category;
  final String phase;
  final int startedAtMicros;
  final int durationMicros;
  final DateTime wallTime;
  final int processId;
  final int timelineLaneId;
  final String? isolateName;
  final String? isolateId;
  final Map<String, Object?> arguments;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'name': name,
    'category': category,
    'phase': phase,
    'startedAtMicros': startedAtMicros,
    'durationMicros': durationMicros,
    'wallTime': wallTime.toUtc().toIso8601String(),
    'processId': processId,
    'timelineLaneId': timelineLaneId,
    'timelineLaneIdSource': 'isolate-hash',
    if (isolateName != null) 'isolateName': isolateName,
    if (isolateId != null) 'isolateId': isolateId,
    'arguments': arguments,
  };

  Map<String, Object?> toChromeTraceJson() => {
    'name': name,
    'cat': category,
    'ph': phase,
    'ts': startedAtMicros,
    if (phase == 'X') 'dur': durationMicros,
    if (phase == 'i') 's': 't',
    'pid': processId,
    'tid': timelineLaneId,
    'args': {
      ...arguments,
      if (isolateName != null) 'isolateName': isolateName,
      if (isolateId != null) 'isolateId': isolateId,
      'timelineLaneIdSource': 'isolate-hash',
      'wallTime': wallTime.toUtc().toIso8601String(),
    },
  };
}

class TraceSpan {
  TraceSpan._({
    required this._recorder,
    required this.name,
    required this.category,
    required this.startedAtMicros,
    required this.wallTime,
    required this.processId,
    required this.timelineLaneId,
    required this.isolateName,
    required this.isolateId,
    required this.arguments,
    required this._task,
  });

  final TraceRecorder _recorder;
  final developer.TimelineTask _task;
  final String name;
  final String category;
  final int startedAtMicros;
  final DateTime wallTime;
  final int processId;
  final int timelineLaneId;
  final String? isolateName;
  final String? isolateId;
  final Map<String, Object?> arguments;

  bool _finished = false;

  bool get isFinished => _finished;

  void finish({Map<String, Object?> arguments = const {}}) {
    if (_finished) throw StateError('trace span is already finished');
    _recorder._finishSpan(this, arguments);
  }
}

class TraceRecorder {
  TraceRecorder({
    int capacity = 2000,
    this.maxOpenSpans = 128,
    TraceClock? traceClock,
    WallClock? wallClock,
  }) : _events = BoundedBuffer<TraceEvent>(capacity),
       _traceClock = traceClock ?? _timelineNow,
       _wallClock = wallClock ?? DateTime.now {
    if (maxOpenSpans < 1 || maxOpenSpans > 10000) {
      throw RangeError.range(maxOpenSpans, 1, 10000, 'maxOpenSpans');
    }
  }

  final BoundedBuffer<TraceEvent> _events;
  final int maxOpenSpans;
  final TraceClock _traceClock;
  final WallClock _wallClock;
  final Set<TraceSpan> _openSpans = <TraceSpan>{};

  bool _recording = false;
  bool _disposed = false;
  int _sequence = 0;

  bool get isRecording => _recording;
  bool get isDisposed => _disposed;
  int get capacity => _events.capacity;
  int get droppedEvents => _events.dropped;
  int get openSpanCount => _openSpans.length;

  void start({bool clear = false}) {
    _checkActive();
    if (clear) this.clear();
    _recording = true;
  }

  void stop() {
    if (!_recording) return;
    _recording = false;
    for (final span in _openSpans.toList(growable: false)) {
      _finishSpan(span, const {'cancelled': true});
    }
  }

  TraceSpan? startSpan(
    String name, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) {
    _checkActive();
    if (!_recording) return null;
    _validateName(name, 'name');
    _validateName(category, 'category');
    if (_openSpans.length == maxOpenSpans) {
      throw StateError('trace recorder has $maxOpenSpans open spans');
    }
    final safeArguments = _sanitizeMap(arguments);
    final task = developer.TimelineTask(filterKey: 'ai_debug')
      ..start(name, arguments: safeArguments);
    final isolate = Isolate.current;
    final span = TraceSpan._(
      recorder: this,
      name: name,
      category: category,
      startedAtMicros: _traceClock(),
      wallTime: _wallClock(),
      processId: pid,
      timelineLaneId: isolate.hashCode,
      isolateName: _traceText(isolate.debugName),
      isolateId: _traceText(developer.Service.getIsolateId(isolate)),
      arguments: safeArguments,
      task: task,
    );
    _openSpans.add(span);
    return span;
  }

  void instant(
    String name, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) {
    _checkActive();
    if (!_recording) return;
    _validateName(name, 'name');
    _validateName(category, 'category');
    final safeArguments = _sanitizeMap(arguments);
    developer.Timeline.instantSync(name, arguments: safeArguments);
    final isolate = Isolate.current;
    _events.add(
      TraceEvent(
        sequence: ++_sequence,
        name: name,
        category: category,
        phase: 'i',
        startedAtMicros: _traceClock(),
        durationMicros: 0,
        wallTime: _wallClock(),
        processId: pid,
        timelineLaneId: isolate.hashCode,
        isolateName: _traceText(isolate.debugName),
        isolateId: _traceText(developer.Service.getIsolateId(isolate)),
        arguments: safeArguments,
      ),
    );
  }

  T timeSync<T>(
    String name,
    T Function() action, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) {
    final span = startSpan(name, category: category, arguments: arguments);
    try {
      return action();
    } catch (error) {
      span?.finish(arguments: {'errorType': error.runtimeType.toString()});
      rethrow;
    } finally {
      if (span != null && !span.isFinished) span.finish();
    }
  }

  Future<T> timeAsync<T>(
    String name,
    FutureOr<T> Function() action, {
    String category = 'app',
    Map<String, Object?> arguments = const {},
  }) async {
    final span = startSpan(name, category: category, arguments: arguments);
    try {
      return await action();
    } catch (error) {
      span?.finish(arguments: {'errorType': error.runtimeType.toString()});
      rethrow;
    } finally {
      if (span != null && !span.isFinished) span.finish();
    }
  }

  List<TraceEvent> events({int? limit}) => _events.tail(limit);

  Map<String, Object?> status() => {
    'source': 'ai_debug-in-process-trace',
    'scope':
        'events recorded through this TraceRecorder in the current isolate',
    'recording': isRecording,
    'capacity': capacity,
    'eventCount': _events.length,
    'droppedEvents': droppedEvents,
    'openSpans': openSpanCount,
    'maxOpenSpans': maxOpenSpans,
    'limits': const {
      'vmTimeline':
          'Full Dart, engine, GC, and compiler events require VM service.',
      'isolates':
          'Other isolates need their own recorder or explicit forwarding.',
      'timelineLaneId':
          'Chrome trace tid is a synthetic isolate lane, not an operating-system thread id.',
    },
  };

  Map<String, Object?> exportChromeTrace({int? limit}) => {
    'traceEvents': [
      for (final event in events(limit: limit)) event.toChromeTraceJson(),
    ],
    'displayTimeUnit': 'ms',
    'metadata': {
      'source': 'ai_debug-in-process-trace',
      'scope': 'instrumented events only',
      'droppedEvents': droppedEvents,
      'openSpansExcluded': openSpanCount,
      'limits': 'This is not a VM or engine timeline.',
    },
  };

  void clear() => _events.clear();

  void dispose() {
    if (_disposed) return;
    stop();
    _events.clear();
    _disposed = true;
  }

  void _finishSpan(TraceSpan span, Map<String, Object?> finishArguments) {
    if (span._finished) throw StateError('trace span is already finished');
    if (!identical(span._recorder, this)) {
      throw ArgumentError('trace span belongs to another recorder');
    }
    span._finished = true;
    _openSpans.remove(span);
    final safeFinishArguments = _sanitizeMap(finishArguments);
    span._task.finish(arguments: Map<String, Object?>.of(safeFinishArguments));
    final finishedAt = _traceClock();
    _events.add(
      TraceEvent(
        sequence: ++_sequence,
        name: span.name,
        category: span.category,
        phase: 'X',
        startedAtMicros: span.startedAtMicros,
        durationMicros: finishedAt > span.startedAtMicros
            ? finishedAt - span.startedAtMicros
            : 0,
        wallTime: span.wallTime,
        processId: span.processId,
        timelineLaneId: span.timelineLaneId,
        isolateName: span.isolateName,
        isolateId: span.isolateId,
        arguments: Map<String, Object?>.unmodifiable({
          ...span.arguments,
          ...safeFinishArguments,
        }),
      ),
    );
  }

  void _checkActive() {
    if (_disposed) throw StateError('trace recorder is disposed');
  }

  static int _timelineNow() => developer.Timeline.now;
}

Map<String, Object?> _sanitizeMap(Map<String, Object?> value) {
  try {
    return _ArgumentSanitizer().sanitizeMap(value);
  } catch (_) {
    return const {'arguments': '<unavailable>'};
  }
}

class _ArgumentSanitizer {
  static const _maxDepth = 8;
  static const _maxItems = 256;
  static const _maxMapItems = 64;
  static const _maxListItems = 100;
  static const _maxStringLength = 1000;
  static const _maxKeyLength = 256;
  static const _maxStringUnits = 8192;

  var _items = 0;
  var _stringUnits = 0;

  Map<String, Object?> sanitizeMap(Map<String, Object?> value) =>
      _map(value, 0);

  Object? _value(Object? value, int depth) {
    if (_items == _maxItems) return '<truncated>';
    _items++;
    if (value == null || value is bool || value is int) return value;
    if (value is double) {
      return value.isFinite ? value : '<non-finite:$value>';
    }
    if (value is num) return value;
    if (value is String) return _text(value, _maxStringLength);
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Duration) return value.inMicroseconds;
    if (depth >= _maxDepth) return '<max-depth>';
    if (value is Map<Object?, Object?>) return _map(value, depth + 1);
    if (value is Iterable<Object?>) return _list(value, depth + 1);
    return _text(_safeText(value), _maxStringLength);
  }

  Map<String, Object?> _map(Map<Object?, Object?> value, int depth) {
    final result = <String, Object?>{};
    var count = 0;
    for (final entry in value.entries) {
      if (count == _maxMapItems || _items == _maxItems) {
        result['_truncated'] = true;
        break;
      }
      final key = _text(_safeText(entry.key), _maxKeyLength);
      result[key] = _value(entry.value, depth);
      count++;
    }
    return Map<String, Object?>.unmodifiable(result);
  }

  List<Object?> _list(Iterable<Object?> value, int depth) {
    final result = <Object?>[];
    final iterator = value.iterator;
    while (result.length < _maxListItems &&
        _items < _maxItems &&
        iterator.moveNext()) {
      result.add(_value(iterator.current, depth));
    }
    if (_items == _maxItems || iterator.moveNext()) {
      result.add('<truncated>');
    }
    return List<Object?>.unmodifiable(result);
  }

  String _text(String value, int limit) {
    final available = _maxStringUnits - _stringUnits;
    if (available <= 0) return '';
    final take = value.length < limit ? value.length : limit;
    final bounded = take < available ? take : available;
    _stringUnits += bounded;
    if (bounded == value.length) return value;
    if (bounded == 0) return '';
    return '${value.substring(0, bounded - 1)}…';
  }
}

String _safeText(Object? value) {
  try {
    return value.toString();
  } catch (_) {
    return '<unavailable>';
  }
}

void _validateName(String value, String name) {
  if (value.isEmpty || value.length > 256) {
    throw ArgumentError.value(value, name, 'must contain 1 to 256 characters');
  }
}

String? _traceText(String? value) {
  if (value == null || value.length <= 512) return value;
  return '${value.substring(0, 511)}…';
}
