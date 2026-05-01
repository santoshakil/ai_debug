import 'dart:collection';
import 'package:logging/logging.dart';

/// Bounded ring buffer of Dart-side [LogRecord]s.
///
/// We keep the `logging` package's `LogRecord` directly to avoid conversion
/// cost on the hot path; encoding happens only when a caller queries logs.
class DartLogBuffer {
  final int capacity;
  final Queue<LogRecord> _records = Queue();

  DartLogBuffer({this.capacity = 2000});

  void push(LogRecord r) {
    _records.add(r);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
  }

  /// Most-recent-first up to [limit], optionally filtered.
  Iterable<LogRecord> tail({
    int limit = 200,
    Level? minLevel,
    String? grep,
    DateTime? since,
  }) sync* {
    var emitted = 0;
    for (final r in _records.toList(growable: false).reversed) {
      if (emitted >= limit) break;
      if (minLevel != null && r.level < minLevel) continue;
      if (since != null && r.time.isBefore(since)) continue;
      if (grep != null && !r.message.contains(grep)) continue;
      yield r;
      emitted++;
    }
  }
}
