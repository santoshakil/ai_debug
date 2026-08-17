import 'dart:collection';

import 'package:logging/logging.dart';

class AiDebugLogRecord {
  const AiDebugLogRecord({
    required this.level,
    required this.message,
    required this.loggerName,
    required this.time,
    required this.sequenceNumber,
    this.error,
    this.stackTrace,
  });

  final Level level;
  final String message;
  final String loggerName;
  final DateTime time;
  final int sequenceNumber;
  final String? error;
  final String? stackTrace;

  int get bytes =>
      message.length * 2 +
      loggerName.length * 2 +
      (error?.length ?? 0) * 2 +
      (stackTrace?.length ?? 0) * 2 +
      128;
}

class DartLogBuffer {
  DartLogBuffer({this.capacity = 2000, this.maxBytes = 2 * 1024 * 1024}) {
    if (capacity < 1 || maxBytes < 1) throw ArgumentError('invalid log limits');
  }

  final int capacity;
  final int maxBytes;
  final Queue<AiDebugLogRecord> _records = Queue();
  var _bytes = 0;
  var _dropped = 0;

  int get length => _records.length;
  int get bytes => _bytes;
  int get dropped => _dropped;

  void push(LogRecord record) {
    final safe = AiDebugLogRecord(
      level: record.level,
      message: _cut(record.message, 16384),
      loggerName: _cut(record.loggerName, 512),
      time: record.time,
      sequenceNumber: record.sequenceNumber,
      error: _text(record.error, 4096),
      stackTrace: record.stackTrace == null
          ? null
          : _text(record.stackTrace, 16384),
    );
    _records.add(safe);
    _bytes += safe.bytes;
    while (_records.length > capacity || _bytes > maxBytes) {
      _bytes -= _records.removeFirst().bytes;
      _dropped++;
    }
  }

  void clear() {
    _records.clear();
    _bytes = 0;
    _dropped = 0;
  }

  Iterable<AiDebugLogRecord> tail({
    int limit = 200,
    Level? minLevel,
    String? grep,
    DateTime? since,
  }) sync* {
    var emitted = 0;
    for (final record in _records.toList(growable: false).reversed) {
      if (emitted >= limit) break;
      if (minLevel != null && record.level < minLevel) continue;
      if (since != null && record.time.isBefore(since)) continue;
      if (grep != null && !record.message.contains(grep)) continue;
      yield record;
      emitted++;
    }
  }
}

String _cut(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

String? _text(Object? value, int max) {
  if (value == null) return null;
  try {
    return _cut(value.toString(), max);
  } catch (_) {
    return '<unavailable>';
  }
}
