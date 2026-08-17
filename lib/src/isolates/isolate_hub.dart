import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:isolate';

import '../internal/json_value.dart';

class IsolateHub {
  IsolateHub({
    this.capacity = 1000,
    this.maxIsolates = 256,
    this.staleAfter = const Duration(seconds: 15),
  }) {
    if (capacity < 1 || maxIsolates < 1 || staleAfter <= Duration.zero) {
      throw ArgumentError('invalid isolate hub limits');
    }
  }

  final int capacity;
  final int maxIsolates;
  final Duration staleAfter;
  final Queue<IsolateEvent> _events = Queue();
  final Map<String, IsolateInfo> _isolates = {};
  ReceivePort? _port;
  StreamSubscription<dynamic>? _subscription;
  var _sequence = 0;
  var _dropped = 0;

  bool get isStarted => _port != null;
  int get dropped => _dropped;
  SendPort get sendPort =>
      _port?.sendPort ?? (throw StateError('isolate hub is not started'));

  void start() {
    if (isStarted) return;
    final port = ReceivePort('ai_debug.isolates');
    _port = port;
    _subscription = port.listen(_receive);
  }

  List<IsolateInfo> isolates() {
    _prune(DateTime.now());
    final values = _isolates.values.toList(growable: false);
    values.sort((a, b) => a.name.compareTo(b.name));
    return values;
  }

  List<IsolateEvent> history({int? after, int limit = 100}) {
    if (limit < 1) {
      throw RangeError.range(limit, 1, null, 'limit');
    }
    final values = [
      for (final event in _events)
        if (after == null || event.sequence > after) event,
    ];
    if (values.length <= limit) return values;
    return values.sublist(values.length - limit);
  }

  void clear() {
    _events.clear();
    _dropped = 0;
  }

  Future<void> dispose() async {
    final subscription = _subscription;
    _subscription = null;
    final port = _port;
    _port = null;
    Object? error;
    StackTrace? stack;
    try {
      await subscription?.cancel();
    } catch (caught, caughtStack) {
      error = caught;
      stack = caughtStack;
    }
    try {
      port?.close();
    } catch (caught, caughtStack) {
      error ??= caught;
      stack ??= caughtStack;
    }
    _isolates.clear();
    clear();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }

  void _receive(dynamic raw) {
    if (raw is! Map) return;
    if (raw.keys.any((key) => key is! String)) return;
    final message = <String, Object?>{
      for (final entry in raw.entries) entry.key as String: entry.value,
    };
    final id = message['id'];
    final name = message['name'];
    final kind = message['kind'];
    if (id is! String || name is! String || kind is! String) return;
    if (id.isEmpty ||
        name.isEmpty ||
        kind.isEmpty ||
        id.length > 256 ||
        name.length > 256 ||
        kind.length > 128) {
      return;
    }
    final now = DateTime.now();
    _prune(now);
    if (kind == 'exit') {
      _isolates.remove(id);
    } else {
      final previous = _isolates[id];
      if (previous == null && _isolates.length >= maxIsolates) {
        _removeOldest();
      }
      _isolates[id] = IsolateInfo(
        id: id,
        name: name,
        debugName: _text(message['debugName']),
        serviceId: _text(message['serviceId']),
        joinedAt: previous?.joinedAt ?? now,
        lastSeenAt: now,
      );
    }
    if (kind != 'heartbeat') {
      _events.add(
        IsolateEvent(
          sequence: ++_sequence,
          isolateId: id,
          isolateName: name,
          timestamp: now,
          kind: kind,
          data: toJsonValue(
            message['data'],
            maxItems: 256,
            maxStringLength: 4096,
            maxStringUnits: 16384,
          ),
        ),
      );
      while (_events.length > capacity) {
        _events.removeFirst();
        _dropped++;
      }
    }
  }

  void _prune(DateTime now) {
    _isolates.removeWhere(
      (_, isolate) => now.difference(isolate.lastSeenAt) > staleAfter,
    );
  }

  void _removeOldest() {
    if (_isolates.isEmpty) return;
    final oldest = _isolates.values.reduce(
      (a, b) => a.lastSeenAt.isAfter(b.lastSeenAt) ? b : a,
    );
    _isolates.remove(oldest.id);
  }
}

class IsolateInfo {
  const IsolateInfo({
    required this.id,
    required this.name,
    required this.joinedAt,
    required this.lastSeenAt,
    this.debugName,
    this.serviceId,
  });

  final String id;
  final String name;
  final String? debugName;
  final String? serviceId;
  final DateTime joinedAt;
  final DateTime lastSeenAt;

  Map<String, Object?> toJson(Duration staleAfter) => {
    'id': id,
    'name': name,
    if (debugName != null) 'debugName': debugName,
    if (serviceId != null) 'serviceId': serviceId,
    'joinedAt': joinedAt.toIso8601String(),
    'lastSeenAt': lastSeenAt.toIso8601String(),
    'stale': DateTime.now().difference(lastSeenAt) > staleAfter,
  };
}

class IsolateEvent {
  const IsolateEvent({
    required this.sequence,
    required this.isolateId,
    required this.isolateName,
    required this.timestamp,
    required this.kind,
    required this.data,
  });

  final int sequence;
  final String isolateId;
  final String isolateName;
  final DateTime timestamp;
  final String kind;
  final Object? data;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'isolateId': isolateId,
    'isolateName': isolateName,
    'timestamp': timestamp.toIso8601String(),
    'timestampMs': timestamp.millisecondsSinceEpoch,
    'kind': kind,
    if (data != null) 'data': data,
  };
}

class AiDebugIsolateClient {
  AiDebugIsolateClient._({
    required this.name,
    required this._hub,
    required Duration heartbeat,
  }) : id =
           '${DateTime.now().microsecondsSinceEpoch}-${Isolate.current.hashCode}' {
    _send('join');
    _timer = Timer.periodic(heartbeat, (_) => _send('heartbeat'));
  }

  factory AiDebugIsolateClient.attach(
    SendPort hub, {
    required String name,
    Duration heartbeat = const Duration(seconds: 5),
  }) {
    if (name.isEmpty || name.length > 256 || heartbeat <= Duration.zero) {
      throw ArgumentError('invalid isolate client settings');
    }
    return AiDebugIsolateClient._(name: name, hub: hub, heartbeat: heartbeat);
  }

  final String id;
  final String name;
  final SendPort _hub;
  Timer? _timer;
  var _disposed = false;

  void event(String kind, [Object? data]) {
    if (_disposed) throw StateError('isolate client is disposed');
    if (kind.isEmpty || kind.length > 128) {
      throw ArgumentError.value(kind, 'kind', 'invalid event kind');
    }
    _send(kind, data);
  }

  void error(Object error, StackTrace stack) => event('error', {
    'error': _textValue(error, 4096),
    'stack': _textValue(stack, 16384),
  });

  void dispose() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _send('exit');
    _disposed = true;
  }

  void _send(String kind, [Object? data]) {
    final isolate = Isolate.current;
    _hub.send({
      'id': id,
      'name': name,
      'kind': kind,
      'debugName': isolate.debugName,
      'serviceId': developer.Service.getIsolateId(isolate),
      if (data != null)
        'data': toJsonValue(
          data,
          maxItems: 256,
          maxStringLength: 4096,
          maxStringUnits: 16384,
        ),
    });
  }
}

String? _text(Object? value) => value is String ? _cut(value, 512) : null;

String _cut(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

String _textValue(Object value, int max) {
  try {
    return _cut(value.toString(), max);
  } catch (_) {
    return '<unavailable>';
  }
}
