import 'dart:async';
import 'dart:collection';

import '../internal/json_value.dart';

typedef StateSnapshot = FutureOr<Object?> Function();
typedef StateRedactor = Object? Function(Object? value);
typedef StateChanges = Stream<Object?> Function();

class StateSource {
  const StateSource({
    required this.name,
    required this.snapshot,
    this.changes,
    this.changesFactory,
    this.redactor,
    this.sensitive = false,
    this.timeout = const Duration(seconds: 3),
  });

  final String name;
  final StateSnapshot snapshot;
  final Stream<Object?>? changes;
  final StateChanges? changesFactory;
  final StateRedactor? redactor;
  final bool sensitive;
  final Duration timeout;
}

class StateRegistry {
  StateRegistry({this.capacity = 256}) {
    if (capacity < 1) {
      throw RangeError.range(capacity, 1, null, 'capacity');
    }
  }

  final int capacity;
  final _sources = <String, _SourceState>{};
  final Queue<StateEvent> _events = Queue();
  var _sequence = 0;
  var _dropped = 0;

  int get length => _sources.length;
  int get eventCount => _events.length;
  int get dropped => _dropped;

  List<StateSourceInfo> get sources {
    final values = [for (final state in _sources.values) state.info];
    values.sort((a, b) => a.name.compareTo(b.name));
    return values;
  }

  void add(StateSource source) {
    _validate(source);
    if (_sources.containsKey(source.name)) {
      throw StateError('state source already registered: ${source.name}');
    }
    final state = _SourceState(source);
    _sources[source.name] = state;
    state.active = true;
    try {
      final changes = source.changesFactory?.call() ?? source.changes;
      if (changes != null) {
        state.subscription = changes.listen(
          (value) {
            if (!state.active) return;
            try {
              _record(state, value);
            } catch (_) {
              return;
            }
          },
          onError: (Object error, StackTrace _) {
            if (state.active) _recordError(state, error);
          },
        );
      }
    } catch (_) {
      state.active = false;
      _sources.remove(source.name);
      rethrow;
    }
  }

  Future<void> remove(String name) async {
    final state = _sources.remove(name);
    if (state == null) return;
    state.active = false;
    await state.subscription?.cancel();
  }

  Future<StateRead> read(String name) async {
    final state = _sources[name];
    if (state == null) throw StateError('unknown state source: $name');
    try {
      final value = await Future<Object?>.sync(
        state.source.snapshot,
      ).timeout(state.source.timeout);
      state.lastReadAt = DateTime.now();
      state.lastError = null;
      return StateRead(
        name: name,
        version: state.version,
        timestamp: state.lastReadAt!,
        value: _safeValue(state.source, value),
      );
    } catch (error, stack) {
      final safeError = _safeError(state.source, error);
      _recordError(state, safeError);
      Error.throwWithStackTrace(safeError, stack);
    }
  }

  void record(String name, Object? value) {
    final state = _sources[name];
    if (state == null) throw StateError('unknown state source: $name');
    _record(state, value);
  }

  void _record(_SourceState state, Object? value) {
    Object? safeValue;
    try {
      safeValue = _safeValue(state.source, value);
    } catch (error, stack) {
      final safeError = _safeError(state.source, error);
      _recordError(state, safeError);
      Error.throwWithStackTrace(safeError, stack);
    }
    final now = DateTime.now();
    state
      ..version = state.version + 1
      ..lastChangeAt = now
      ..lastError = null;
    _events.add(
      StateEvent(
        sequence: ++_sequence,
        name: state.source.name,
        version: state.version,
        timestamp: now,
        value: safeValue,
      ),
    );
    _trim();
  }

  List<StateEvent> history({String? name, int? after, int limit = 100}) {
    if (limit < 1) {
      throw RangeError.range(limit, 1, null, 'limit');
    }
    final values = [
      for (final event in _events)
        if ((name == null || event.name == name) &&
            (after == null || event.sequence > after))
          event,
    ];
    if (values.length <= limit) return values;
    return values.sublist(values.length - limit);
  }

  void clearHistory() {
    _events.clear();
    _dropped = 0;
  }

  Future<void> dispose() async {
    for (final state in _sources.values) {
      state.active = false;
    }
    final subscriptions = [
      for (final state in _sources.values)
        if (state.subscription != null) state.subscription!.cancel(),
    ];
    _sources.clear();
    clearHistory();
    await Future.wait(subscriptions);
  }

  void _recordError(_SourceState state, Object error) {
    final now = DateTime.now();
    final message = state.source.sensitive
        ? _sourceErrorMessage
        : _text(error, 4096);
    state
      ..lastError = message
      ..lastErrorAt = now;
    _events.add(
      StateEvent(
        sequence: ++_sequence,
        name: state.source.name,
        version: state.version,
        timestamp: now,
        error: message,
      ),
    );
    _trim();
  }

  void _trim() {
    while (_events.length > capacity) {
      _events.removeFirst();
      _dropped++;
    }
  }
}

class StateSourceInfo {
  const StateSourceInfo({
    required this.name,
    required this.version,
    required this.sensitive,
    required this.hasChanges,
    required this.timeout,
    this.lastReadAt,
    this.lastChangeAt,
    this.lastErrorAt,
    this.lastError,
  });

  final String name;
  final int version;
  final bool sensitive;
  final bool hasChanges;
  final Duration timeout;
  final DateTime? lastReadAt;
  final DateTime? lastChangeAt;
  final DateTime? lastErrorAt;
  final String? lastError;

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'sensitive': sensitive,
    'hasChanges': hasChanges,
    'timeoutMs': timeout.inMilliseconds,
    if (lastReadAt != null) 'lastReadAt': lastReadAt!.toIso8601String(),
    if (lastChangeAt != null) 'lastChangeAt': lastChangeAt!.toIso8601String(),
    if (lastErrorAt != null) 'lastErrorAt': lastErrorAt!.toIso8601String(),
    if (lastError != null) 'lastError': lastError,
  };
}

class StateRead {
  const StateRead({
    required this.name,
    required this.version,
    required this.timestamp,
    required this.value,
  });

  final String name;
  final int version;
  final DateTime timestamp;
  final Object? value;

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'timestamp': timestamp.toIso8601String(),
    'timestampMs': timestamp.millisecondsSinceEpoch,
    'value': value,
  };
}

class StateEvent {
  const StateEvent({
    required this.sequence,
    required this.name,
    required this.version,
    required this.timestamp,
    this.value,
    this.error,
  });

  final int sequence;
  final String name;
  final int version;
  final DateTime timestamp;
  final Object? value;
  final String? error;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'name': name,
    'version': version,
    'timestamp': timestamp.toIso8601String(),
    'timestampMs': timestamp.millisecondsSinceEpoch,
    if (error == null) 'value': value,
    if (error != null) 'error': error,
  };
}

class _SourceState {
  _SourceState(this.source);

  final StateSource source;
  StreamSubscription<Object?>? subscription;
  var active = false;
  var version = 0;
  DateTime? lastReadAt;
  DateTime? lastChangeAt;
  DateTime? lastErrorAt;
  String? lastError;

  StateSourceInfo get info => StateSourceInfo(
    name: source.name,
    version: version,
    sensitive: source.sensitive,
    hasChanges: source.changes != null || source.changesFactory != null,
    timeout: source.timeout,
    lastReadAt: lastReadAt,
    lastChangeAt: lastChangeAt,
    lastErrorAt: lastErrorAt,
    lastError: lastError,
  );
}

void _validate(StateSource source) {
  if (source.name.isEmpty ||
      source.name.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(source.name)) {
    throw ArgumentError.value(source.name, 'name', 'invalid state source name');
  }
  if (source.timeout <= Duration.zero) {
    throw ArgumentError.value(source.timeout, 'timeout', 'must be positive');
  }
  if (source.changes != null && source.changesFactory != null) {
    throw ArgumentError('pass changes or changesFactory, not both');
  }
}

Object? _safeValue(StateSource source, Object? value) {
  final redactor = source.redactor;
  if (redactor != null) {
    try {
      return toJsonValue(
        redactor(value),
        maxItems: 256,
        maxStringLength: 4096,
        maxStringUnits: 65536,
      );
    } catch (_) {
      throw StateError(_redactionErrorMessage);
    }
  }
  if (source.sensitive) return '[redacted]';
  return toJsonValue(
    value,
    maxItems: 256,
    maxStringLength: 4096,
    maxStringUnits: 65536,
  );
}

Object _safeError(StateSource source, Object error) =>
    source.sensitive ? StateError(_sourceErrorMessage) : error;

const _sourceErrorMessage = 'state source failed';
const _redactionErrorMessage = 'state redaction failed';

String _cut(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

String _text(Object value, int max) {
  try {
    return _cut(value.toString(), max);
  } catch (_) {
    return '<unavailable>';
  }
}
