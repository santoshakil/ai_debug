import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

class VmServiceClient {
  VmServiceClient._()
    : _serviceUri = _readServiceUri,
      _connectSocket = _openSocket,
      _connectTimeout = const Duration(seconds: 10),
      _callTimeout = const Duration(seconds: 10),
      _disposeTimeout = const Duration(seconds: 1);

  factory VmServiceClient.testing({
    required Future<Uri?> Function() serviceUri,
    required Future<WebSocket> Function(String) connectSocket,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration callTimeout = const Duration(seconds: 10),
    Duration disposeTimeout = const Duration(seconds: 1),
  }) => VmServiceClient._with(
    serviceUri,
    connectSocket,
    connectTimeout,
    callTimeout,
    disposeTimeout,
  );

  VmServiceClient._with(
    this._serviceUri,
    this._connectSocket,
    this._connectTimeout,
    this._callTimeout,
    this._disposeTimeout,
  );

  static final VmServiceClient instance = VmServiceClient._();
  static const _maxMessageBytes = 32 * 1024 * 1024;

  final Future<Uri?> Function() _serviceUri;
  final Future<WebSocket> Function(String) _connectSocket;
  final Duration _connectTimeout;
  final Duration _callTimeout;
  final Duration _disposeTimeout;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  WebSocket? _socket;
  Future<WebSocket>? _connecting;
  _ConnectAttempt? _attempt;
  StreamSubscription<dynamic>? _subscription;
  var _nextId = 1;
  var _generation = 0;

  bool get isConnected => _socket?.readyState == WebSocket.open;
  int get pendingCallCount => _pending.length;

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final generation = _generation;
    final socket = await _connect();
    if (generation != _generation || !identical(_socket, socket)) {
      throw StateError('VM service connection was disposed');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          if (params.isNotEmpty) 'params': params,
        }),
      );
      return await completer.future.timeout(_callTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  Future<Map<String, Object?>> status() async {
    final info = await developer.Service.getInfo();
    return {
      'available': info.serverWebSocketUri != null,
      'protocol': '${info.majorVersion}.${info.minorVersion}',
      'source': 'vmService',
      'scope': 'current Dart VM',
    };
  }

  Future<void> dispose() async {
    ++_generation;
    _attempt?.cancel();
    _attempt = null;
    _connecting = null;
    final socket = _socket;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    _failPending(StateError('VM service connection closed'));
    if (subscription != null) {
      await _settle(subscription.cancel);
    }
    if (socket != null) {
      await _settle(() => socket.close());
    }
  }

  Future<WebSocket> _connect() async {
    final socket = _socket;
    if (socket != null && socket.readyState == WebSocket.open) return socket;
    final active = _connecting;
    if (active != null) return active;
    final attempt = _ConnectAttempt(_generation);
    final future = _open(attempt);
    _attempt = attempt;
    _connecting = future;
    try {
      return await future;
    } finally {
      if (identical(_attempt, attempt)) _attempt = null;
      if (identical(_connecting, future)) _connecting = null;
    }
  }

  Future<WebSocket> _open(_ConnectAttempt attempt) async {
    final Uri? uri;
    try {
      uri = await attempt.wait(_serviceUri()).timeout(_connectTimeout);
    } on TimeoutException {
      attempt.cancel();
      rethrow;
    }
    if (uri == null) {
      throw StateError('Dart VM service is unavailable in this build');
    }
    if (attempt.cancelled || attempt.generation != _generation) {
      throw StateError('VM service connection was disposed');
    }
    final opening = _connectSocket(uri.toString());
    unawaited(
      opening.then((socket) async {
        if (attempt.cancelled && !attempt.claimed) {
          attempt.claimed = true;
          await _settle(() => socket.close());
        }
      }, onError: (_) {}),
    );
    final WebSocket socket;
    try {
      socket = await attempt.wait(opening).timeout(_connectTimeout);
    } on TimeoutException {
      attempt.cancel();
      rethrow;
    }
    if (attempt.cancelled || attempt.generation != _generation) {
      if (!attempt.claimed) {
        attempt.claimed = true;
        await _settle(() => socket.close());
      }
      throw StateError('VM service connection was disposed');
    }
    attempt.claimed = true;
    _socket = socket;
    _subscription = socket.listen(
      (raw) => _onMessage(socket, attempt.generation, raw),
      onDone: () => _onDone(socket, attempt.generation),
      onError: (Object error, StackTrace stackTrace) =>
          _onError(socket, attempt.generation, error, stackTrace),
      cancelOnError: true,
    );
    return socket;
  }

  void _onMessage(WebSocket socket, int generation, dynamic raw) {
    if (!identical(_socket, socket) || generation != _generation) return;
    if (raw is! String) return;
    if (raw.length > _maxMessageBytes) {
      _socket?.close();
      _socket = null;
      _failPending(StateError('VM service response exceeds 32 MiB'));
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = message['error'];
    if (error is Map) {
      completer.completeError(
        VmServiceError(
          error['code'] as int? ?? -1,
          _cut(error['message']?.toString() ?? 'VM service error', 4096),
        ),
      );
      return;
    }
    final result = message['result'];
    if (result is! Map) {
      completer.completeError(
        const FormatException('invalid VM service result'),
      );
      return;
    }
    completer.complete(Map<String, dynamic>.from(result));
  }

  void _onDone(WebSocket socket, int generation) {
    if (!identical(_socket, socket) || generation != _generation) return;
    _socket = null;
    _subscription = null;
    _failPending(StateError('VM service connection closed'));
  }

  void _onError(
    WebSocket socket,
    int generation,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!identical(_socket, socket) || generation != _generation) return;
    _socket = null;
    _subscription = null;
    _failPending(error, stackTrace);
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(error, stackTrace);
    }
  }

  Future<void> _settle(Future<void> Function() action) async {
    try {
      await action().timeout(_disposeTimeout);
    } catch (_) {}
  }
}

Future<Uri?> _readServiceUri() async =>
    (await developer.Service.getInfo()).serverWebSocketUri;

Future<WebSocket> _openSocket(String url) => WebSocket.connect(url);

class _ConnectAttempt {
  final int generation;
  final _cancelled = Completer<void>();
  var cancelled = false;
  var claimed = false;

  _ConnectAttempt(this.generation);

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelled.complete();
  }

  Future<T> wait<T>(Future<T> future) {
    if (cancelled) {
      return Future.error(StateError('VM service connection was disposed'));
    }
    return Future.any([
      future,
      _cancelled.future.then<T>(
        (_) => throw StateError('VM service connection was disposed'),
      ),
    ]);
  }
}

String _cut(String value, int max) => value.length <= max
    ? value
    : max < 1
    ? ''
    : max == 1
    ? '…'
    : '${value.substring(0, max - 1)}…';

class VmServiceError implements Exception {
  final int code;
  final String message;

  const VmServiceError(this.code, this.message);

  @override
  String toString() => 'VM service error $code: $message';
}
