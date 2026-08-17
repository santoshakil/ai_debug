import 'dart:collection';

class NetworkMonitor {
  NetworkMonitor({this.capacity = 1000, this.maxActive = 1000}) {
    if (capacity < 1 || maxActive < 1) {
      throw RangeError.range(capacity, 1, null, 'capacity');
    }
  }

  final int capacity;
  final int maxActive;
  final Queue<NetworkEvent> _events = Queue();
  final Map<int, NetworkRequest> _active = {};
  var _sequence = 0;
  var _dropped = 0;

  int get length => _events.length;
  int get activeCount => _active.length;
  int get dropped => _dropped;

  NetworkRequest start({
    required String method,
    required Uri uri,
    int? requestBytes,
    String? client,
  }) {
    if (method.trim() != method ||
        method.isEmpty ||
        method.length > 32 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(method)) {
      throw ArgumentError.value(method, 'method', 'invalid method');
    }
    if (requestBytes != null && requestBytes < 0) {
      throw RangeError.range(requestBytes, 0, null, 'requestBytes');
    }
    if (_active.length >= maxActive) {
      throw StateError('too many active network requests');
    }
    final request = NetworkRequest._(
      monitor: this,
      id: ++_sequence,
      method: method.toUpperCase(),
      uri: _redactUri(uri),
      requestBytes: requestBytes,
      client: client == null ? null : _cut(client, 256),
    );
    _active[request.id] = request;
    return request;
  }

  List<NetworkEvent> history({int? after, int limit = 100}) {
    if (limit < 1) {
      throw RangeError.range(limit, 1, null, 'limit');
    }
    return [
      for (final event in _events)
        if (after == null || event.id > after) event,
    ].reversed.take(limit).toList(growable: false).reversed.toList();
  }

  Map<String, Object?> summary() {
    final byStatus = <String, int>{};
    var errors = 0;
    var requestBytes = 0;
    var responseBytes = 0;
    var totalDurationUs = 0;
    for (final event in _events) {
      final bucket = event.status == null
          ? 'none'
          : '${event.status! ~/ 100}xx';
      byStatus[bucket] = (byStatus[bucket] ?? 0) + 1;
      if (event.error != null) errors++;
      requestBytes += event.requestBytes ?? 0;
      responseBytes += event.responseBytes ?? 0;
      totalDurationUs += event.duration.inMicroseconds;
    }
    return {
      'count': _events.length,
      'active': _active.length,
      'capacity': capacity,
      'dropped': _dropped,
      'errors': errors,
      'byStatus': byStatus,
      'requestBytes': requestBytes,
      'responseBytes': responseBytes,
      'meanDurationMs': _events.isEmpty
          ? null
          : totalDurationUs / 1000 / _events.length,
      'source': 'explicit app instrumentation',
      'scope': 'only requests recorded through AiDebug.trackNetwork',
    };
  }

  void clear() {
    _events.clear();
    _dropped = 0;
  }

  void dispose() {
    for (final request in _active.values.toList(growable: false)) {
      request.fail(StateError('ai_debug disposed'));
    }
    _active.clear();
    clear();
  }

  void _finish(NetworkRequest request, NetworkEvent event) {
    if (!identical(_active.remove(request.id), request)) return;
    _events.add(event);
    while (_events.length > capacity) {
      _events.removeFirst();
      _dropped++;
    }
  }
}

class NetworkRequest {
  NetworkRequest._({
    required this._monitor,
    required this.id,
    required this.method,
    required this.uri,
    required this.requestBytes,
    required this.client,
  }) : startedAt = DateTime.now(),
       _stopwatch = Stopwatch()..start();

  final NetworkMonitor _monitor;
  final Stopwatch _stopwatch;
  final int id;
  final String method;
  final Uri uri;
  final int? requestBytes;
  final String? client;
  final DateTime startedAt;
  var _finished = false;

  bool get isFinished => _finished;

  void finish({int? status, int? responseBytes}) =>
      _complete(status: status, responseBytes: responseBytes);

  void fail(Object _, {int? status, int? responseBytes}) => _complete(
    status: status,
    responseBytes: responseBytes,
    error: 'request_failed',
  );

  void _complete({int? status, int? responseBytes, String? error}) {
    if (_finished) return;
    if (status != null && (status < 0 || status > 999)) {
      throw RangeError.range(status, 0, 999, 'status');
    }
    if (responseBytes != null && responseBytes < 0) {
      throw RangeError.range(responseBytes, 0, null, 'responseBytes');
    }
    _finished = true;
    _stopwatch.stop();
    _monitor._finish(
      this,
      NetworkEvent(
        id: id,
        method: method,
        uri: uri,
        startedAt: startedAt,
        duration: _stopwatch.elapsed,
        status: status,
        requestBytes: requestBytes,
        responseBytes: responseBytes,
        client: client,
        error: error == null ? null : _cut(error, 4096),
      ),
    );
  }
}

class NetworkEvent {
  final int id;
  final String method;
  final Uri uri;
  final DateTime startedAt;
  final Duration duration;
  final int? status;
  final int? requestBytes;
  final int? responseBytes;
  final String? client;
  final String? error;

  const NetworkEvent({
    required this.id,
    required this.method,
    required this.uri,
    required this.startedAt,
    required this.duration,
    this.status,
    this.requestBytes,
    this.responseBytes,
    this.client,
    this.error,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'method': method,
    'url': uri.toString(),
    'startedAt': startedAt.toIso8601String(),
    'startedAtMs': startedAt.millisecondsSinceEpoch,
    'durationUs': duration.inMicroseconds,
    'durationMs': duration.inMicroseconds / 1000,
    if (status != null) 'status': status,
    if (requestBytes != null) 'requestBytes': requestBytes,
    if (responseBytes != null) 'responseBytes': responseBytes,
    if (client != null) 'client': client,
    if (error != null) 'error': error,
  };
}

Uri _redactUri(Uri uri) => Uri(
  scheme: _cut(uri.scheme, 32),
  host: _cut(uri.host, 255),
  port: uri.hasPort ? uri.port : null,
  pathSegments: [
    for (final segment in uri.pathSegments.take(64)) _cut(segment, 256),
    if (uri.pathSegments.length > 64) '_truncated_',
  ],
  queryParameters: {
    for (final key in uri.queryParametersAll.keys.take(64))
      _cut(key, 128): '[redacted]',
  },
);

String _cut(String value, int max) => value.length <= max
    ? value
    : max == 1
    ? '…'
    : '${value.substring(0, max - 1)}…';
