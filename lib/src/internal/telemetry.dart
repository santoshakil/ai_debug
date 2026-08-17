import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'json_value.dart';

class Telemetry {
  Telemetry({
    int maxEvents = 2000,
    int maxQueueBytes = 2 * 1024 * 1024,
    int maxEventBytes = 64 * 1024,
    int maxBatchEvents = 100,
    int maxBatchBytes = 256 * 1024,
    int maxPayloadDepth = 12,
    int maxPayloadItems = 1000,
    int maxPayloadStringLength = 16384,
    Duration eventTtl = const Duration(minutes: 30),
    Duration flushInterval = const Duration(seconds: 2),
    Duration connectTimeout = const Duration(seconds: 3),
    Duration requestTimeout = const Duration(seconds: 5),
    this.captureLogs = false,
    this.captureLifecycle = false,
  }) : _maxEvents = maxEvents,
       _maxQueueBytes = maxQueueBytes,
       _maxEventBytes = maxEventBytes,
       _maxBatchEvents = maxBatchEvents,
       _maxBatchBytes = maxBatchBytes,
       _maxPayloadDepth = maxPayloadDepth,
       _maxPayloadItems = maxPayloadItems,
       _maxPayloadStringLength = maxPayloadStringLength,
       _eventTtl = eventTtl,
       _flushInterval = flushInterval,
       _connectTimeout = connectTimeout,
       _requestTimeout = requestTimeout {
    if (maxEvents < 1 ||
        maxQueueBytes <= _batchEnvelopeBytes ||
        maxEventBytes < 1 ||
        maxBatchEvents < 1 ||
        maxBatchBytes <= _batchEnvelopeBytes ||
        maxPayloadDepth < 1 ||
        maxPayloadItems < 1 ||
        maxPayloadStringLength < 1 ||
        eventTtl <= Duration.zero ||
        flushInterval <= Duration.zero ||
        connectTimeout <= Duration.zero ||
        requestTimeout <= Duration.zero) {
      throw ArgumentError('telemetry limits and durations must be positive');
    }
  }

  static final Telemetry I = Telemetry();

  static const _batchEnvelopeBytes = 13;

  final int _maxEvents;
  final int _maxQueueBytes;
  final int _maxEventBytes;
  final int _maxBatchEvents;
  final int _maxBatchBytes;
  final int _maxPayloadDepth;
  final int _maxPayloadItems;
  final int _maxPayloadStringLength;
  final Duration _eventTtl;
  final Duration _flushInterval;
  final Duration _connectTimeout;
  final Duration _requestTimeout;
  final bool captureLogs;
  final bool captureLifecycle;
  final List<_Event> _queue = [];

  Uri? _collectorUri;
  String _appId = '';
  String _isolate = '';
  bool _enabled = false;
  int _queueEventBytes = 0;
  int _generation = 0;
  int _totalSent = 0;
  int _totalFailed = 0;
  int _totalDropped = 0;
  Timer? _timer;
  StreamSubscription<LogRecord>? _logSub;
  _Observer? _observer;
  HttpClient? _client;
  HttpClientRequest? _request;
  Future<void>? _flushFuture;
  Future<void>? _stopping;

  bool get isEnabled => _enabled;
  String? get collectorUrl => _collectorUri?.toString();
  int get queueDepth => _queue.length;
  int get queueBytes => _queue.isEmpty
      ? 0
      : _batchEnvelopeBytes + _queueEventBytes + _queue.length - 1;
  Map<String, int> get stats => {
    'queueDepth': queueDepth,
    'queueBytes': queueBytes,
    'totalSent': _totalSent,
    'totalFailed': _totalFailed,
    'totalDropped': _totalDropped,
  };

  void start({
    required String collectorUrl,
    required String appId,
    String isolate = 'main',
  }) {
    if (_stopping != null) {
      throw StateError('telemetry is stopping');
    }
    final uri = _parseCollectorUri(collectorUrl);
    final nextAppId = _validateLabel(appId, 'appId');
    final nextIsolate = _validateLabel(isolate, 'isolate');
    if (_enabled) {
      if (_collectorUri == uri &&
          _appId == nextAppId &&
          _isolate == nextIsolate) {
        return;
      }
      throw StateError('stop telemetry before changing its configuration');
    }
    _collectorUri = uri;
    _appId = nextAppId;
    _isolate = nextIsolate;
    _enabled = true;
    _generation++;
    _attachObservers();
    _timer = Timer.periodic(_flushInterval, (_) => unawaited(flushNow()));
    emit(
      kind: 'telemetry_start',
      payload: {'appId': _appId, 'isolate': _isolate},
    );
  }

  Future<void> stop() {
    final active = _stopping;
    if (active != null) return active;
    final future = _stop();
    _stopping = future;
    return future.whenComplete(() {
      if (identical(_stopping, future)) _stopping = null;
    });
  }

  Future<void> dispose() => stop();

  void emit({required String kind, Map<String, dynamic>? payload}) {
    final nextKind = _validateKind(kind);
    if (!_enabled) throw StateError('telemetry is not started');
    Object? safe;
    try {
      safe = toJsonValue(
        payload ?? const <String, Object?>{},
        maxDepth: _maxPayloadDepth,
        maxItems: _maxPayloadItems,
        maxStringLength: _maxPayloadStringLength,
      );
    } catch (_) {
      _totalDropped++;
      throw ArgumentError('telemetry payload must be bounded JSON');
    }
    if (safe is! Map<String, Object?>) {
      _totalDropped++;
      throw ArgumentError('telemetry payload must be a JSON object');
    }
    final now = DateTime.now();
    final json = <String, Object?>{
      'kind': nextKind,
      'ts_ms': now.millisecondsSinceEpoch,
      'ts_iso': now.toUtc().toIso8601String(),
      'app_id': _appId,
      'isolate': _isolate,
      'payload': safe,
    };
    late final String encoded;
    try {
      encoded = jsonEncode(json);
    } catch (_) {
      _totalDropped++;
      throw ArgumentError('telemetry event must be JSON encodable');
    }
    final byteLength = utf8.encode(encoded).length;
    if (byteLength > _maxEventBytes ||
        _batchEnvelopeBytes + byteLength > _maxBatchBytes ||
        _batchEnvelopeBytes + byteLength > _maxQueueBytes) {
      _totalDropped++;
      throw ArgumentError('telemetry event exceeds configured limits');
    }
    _queue.add(
      _Event(
        tsMs: now.millisecondsSinceEpoch,
        encoded: encoded,
        byteLength: byteLength,
      ),
    );
    _queueEventBytes += byteLength;
    while (_queue.length > _maxEvents || queueBytes > _maxQueueBytes) {
      _dropFirst();
    }
  }

  Future<void> flushNow() {
    final active = _flushFuture;
    if (active != null) return active;
    if (!_enabled || _queue.isEmpty || _collectorUri == null) {
      return Future.value();
    }
    final generation = _generation;
    final future = _flush(generation);
    _flushFuture = future;
    return future.whenComplete(() {
      if (identical(_flushFuture, future)) _flushFuture = null;
    });
  }

  Future<void> _stop() async {
    _enabled = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    final logSub = _logSub;
    _logSub = null;
    if (logSub != null) {
      try {
        await logSub.cancel();
      } catch (_) {}
    }
    final observer = _observer;
    _observer = null;
    if (observer != null) {
      try {
        WidgetsBinding.instance.removeObserver(observer);
      } catch (_) {}
    }
    try {
      _request?.abort(StateError('telemetry stopped'));
    } catch (_) {}
    final client = _client;
    _client = null;
    client?.close(force: true);
    final flush = _flushFuture;
    if (flush != null) await flush;
    _clearQueue();
    _collectorUri = null;
    _appId = '';
    _isolate = '';
  }

  void _attachObservers() {
    if (captureLogs) {
      _logSub = Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'ai_debug.telemetry' ||
            record.level < Level.WARNING) {
          return;
        }
        try {
          emit(
            kind: 'log',
            payload: {
              'level': record.level.name,
              'logger': record.loggerName,
              'message': record.message,
              if (record.error != null) 'error': record.error,
              if (record.stackTrace != null) 'stack': record.stackTrace,
            },
          );
        } catch (_) {}
      });
    }
    if (!captureLifecycle) return;
    try {
      final binding = WidgetsBinding.instance;
      final observer = _Observer(this);
      binding.addObserver(observer);
      _observer = observer;
      emit(
        kind: 'lifecycle_initial',
        payload: {
          'state': (binding.lifecycleState ?? AppLifecycleState.resumed).name,
        },
      );
    } catch (_) {}
  }

  Future<void> _flush(int generation) async {
    try {
      if (!_enabled || generation != _generation) return;
      final cutoff =
          DateTime.now().millisecondsSinceEpoch - _eventTtl.inMilliseconds;
      while (_queue.isNotEmpty && _queue.first.tsMs < cutoff) {
        _dropFirst();
      }
      if (_queue.isEmpty) return;
      final batch = <_Event>[];
      var byteLength = _batchEnvelopeBytes;
      for (final event in _queue) {
        if (batch.length >= _maxBatchEvents) break;
        final nextBytes = event.byteLength + (batch.isEmpty ? 0 : 1);
        if (byteLength + nextBytes > _maxBatchBytes) break;
        batch.add(event);
        byteLength += nextBytes;
      }
      if (batch.isEmpty) return;
      final body = '{"events":[${batch.map((e) => e.encoded).join(',')}]}';
      final sent = await _post(body);
      if (!_enabled || generation != _generation) return;
      if (!sent) {
        _totalFailed++;
        return;
      }
      final sentEvents = Set<_Event>.identity()..addAll(batch);
      var removed = 0;
      _queue.removeWhere((event) {
        if (!sentEvents.contains(event)) return false;
        _queueEventBytes -= event.byteLength;
        removed++;
        return true;
      });
      _totalSent += removed;
    } catch (_) {
      if (_enabled && generation == _generation) _totalFailed++;
    }
  }

  Future<bool> _post(String body) async {
    final collector = _collectorUri;
    if (collector == null) return false;
    final path = collector.path.isEmpty ? '/event' : '${collector.path}/event';
    final uri = collector.replace(path: path);
    final client = _client ??= _newClient();
    HttpClientRequest? request;
    try {
      request = await client.postUrl(uri).timeout(_connectTimeout);
      _request = request;
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.add(utf8.encode(body));
      final response = await request.close().timeout(_requestTimeout);
      await response.drain<void>().timeout(_requestTimeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      request?.abort();
      if (identical(_client, client)) _client = null;
      client.close(force: true);
      return false;
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  HttpClient _newClient() => HttpClient()
    ..connectionTimeout = _connectTimeout
    ..idleTimeout = _requestTimeout
    ..userAgent = 'ai_debug/telemetry';

  void _dropFirst() {
    final event = _queue.removeAt(0);
    _queueEventBytes -= event.byteLength;
    _totalDropped++;
  }

  void _clearQueue() {
    _totalDropped += _queue.length;
    _queue.clear();
    _queueEventBytes = 0;
  }
}

class _Event {
  const _Event({
    required this.tsMs,
    required this.encoded,
    required this.byteLength,
  });

  final int tsMs;
  final String encoded;
  final int byteLength;
}

class _Observer extends WidgetsBindingObserver {
  _Observer(this.telemetry);

  final Telemetry telemetry;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    telemetry.emit(kind: 'lifecycle', payload: {'state': state.name});
  }
}

Uri _parseCollectorUri(String value) {
  final uri = Uri.tryParse(value);
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (scheme != 'https' && scheme != 'http') ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (scheme == 'http' && !_isLoopback(uri.host))) {
    throw ArgumentError.value(
      value,
      'collectorUrl',
      'must be HTTPS or loopback HTTP without credentials, query, or fragment',
    );
  }
  var path = uri.path;
  while (path.endsWith('/') && path.isNotEmpty) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(scheme: scheme, host: uri.host.toLowerCase(), path: path);
}

bool _isLoopback(String host) {
  final value = host.toLowerCase();
  if (value == 'localhost' || value.endsWith('.localhost')) return true;
  return InternetAddress.tryParse(value)?.isLoopback ?? false;
}

String _validateLabel(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 128 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
    throw ArgumentError.value(value, name, 'must be 1 to 128 safe characters');
  }
  return normalized;
}

String _validateKind(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'kind', 'must be a safe event name');
  }
  return normalized;
}
