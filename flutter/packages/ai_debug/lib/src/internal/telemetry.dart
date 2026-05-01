import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

/// Telemetry pusher.
///
/// Subscribes to Logger.root + WidgetsBindingObserver and sends events to a
/// configured collector URL via HTTP POST. Used to capture cross-restart
/// data from background isolates that would otherwise be invisible — e.g.
/// when iOS fires a BGTaskScheduler task while the foreground app is dead,
/// the BG isolate boots its own telemetry instance and reports its work.
///
/// Designed to be fire-and-forget. A bounded in-memory queue retries on
/// transient failures; events older than a TTL are dropped.
class Telemetry {
  Telemetry._();

  static final Telemetry I = Telemetry._();

  final _log = Logger('ai_debug.telemetry');
  final List<_Event> _queue = [];
  final int _maxQueueSize = 2000;
  final Duration _eventTtl = const Duration(minutes: 30);
  final Duration _flushInterval = const Duration(seconds: 2);
  String? _collectorUrl;
  String _appId = '';
  String _isolate = '';
  bool _enabled = false;
  Timer? _timer;
  StreamSubscription<LogRecord>? _logSub;
  _Observer? _observer;
  bool _flushing = false;
  int _totalSent = 0;
  int _totalFailed = 0;
  int _totalDropped = 0;

  bool get isEnabled => _enabled;
  String? get collectorUrl => _collectorUrl;
  int get queueDepth => _queue.length;
  Map<String, int> get stats => {
        'queueDepth': _queue.length,
        'totalSent': _totalSent,
        'totalFailed': _totalFailed,
        'totalDropped': _totalDropped,
      };

  /// Configure + start the telemetry pump. Idempotent — re-calling updates
  /// the URL without losing the queue.
  void start({required String collectorUrl, required String appId, String isolate = 'main'}) {
    _collectorUrl = collectorUrl.replaceAll(RegExp(r'/+$'), '');
    _appId = appId;
    _isolate = isolate;
    _enabled = true;
    _attachObservers();
    _timer ??= Timer.periodic(_flushInterval, (_) => _flush());
    emit(kind: 'telemetry_start', payload: {
      'collectorUrl': _collectorUrl,
      'appId': _appId,
      'isolate': _isolate,
    });
  }

  void stop() {
    emit(kind: 'telemetry_stop');
    _enabled = false;
    _timer?.cancel();
    _timer = null;
    _logSub?.cancel();
    _logSub = null;
    if (_observer != null) {
      WidgetsBinding.instance.removeObserver(_observer!);
      _observer = null;
    }
  }

  /// Manually emit an event. Auto-attaches app_id, ts_ms, ts_iso, isolate.
  void emit({required String kind, Map<String, dynamic>? payload}) {
    if (!_enabled) return;
    final now = DateTime.now();
    _queue.add(_Event(
      kind: kind,
      tsMs: now.millisecondsSinceEpoch,
      tsIso: now.toIso8601String(),
      appId: _appId,
      isolate: _isolate,
      payload: payload ?? const {},
    ));
    while (_queue.length > _maxQueueSize) {
      _queue.removeAt(0);
      _totalDropped++;
    }
  }

  void _attachObservers() {
    // Log records — capture severe/warning + AI_DEBUG_BG markers + lifecycle.
    _logSub ??= Logger.root.onRecord.listen((r) {
      try {
        // Always emit AI_DEBUG_BG markers
        final isBgMarker = r.message.startsWith('AI_DEBUG_BG ');
        final isSevere = r.level >= Level.WARNING;
        if (!isBgMarker && !isSevere) return;
        emit(
          kind: isBgMarker ? 'bg_marker' : 'log',
          payload: {
            'level': r.level.name,
            'logger': r.loggerName,
            'message': r.message,
            if (r.error != null) 'error': r.error.toString(),
            if (r.stackTrace != null) 'stack': r.stackTrace.toString().split('\n').take(8).join('\n'),
          },
        );
      } catch (_) {}
    });

    // Lifecycle observer (foreground only — bg isolate doesn't have one)
    if (_observer == null) {
      try {
        _observer = _Observer(this);
        WidgetsBinding.instance.addObserver(_observer!);
        // Capture initial state
        final s = WidgetsBinding.instance.lifecycleState;
        emit(kind: 'lifecycle_initial', payload: {'state': (s ?? AppLifecycleState.resumed).name});
      } catch (_) {
        // No WidgetsBinding (e.g., bg isolate) — skip lifecycle observer.
      }
    }
  }

  Future<void> _flush() async {
    if (!_enabled) return;
    if (_flushing) return;
    if (_queue.isEmpty) return;
    if (_collectorUrl == null) return;
    _flushing = true;
    try {
      // Drop events past TTL.
      final cutoffMs = DateTime.now().millisecondsSinceEpoch - _eventTtl.inMilliseconds;
      _queue.removeWhere((e) {
        if (e.tsMs < cutoffMs) {
          _totalDropped++;
          return true;
        }
        return false;
      });
      if (_queue.isEmpty) return;

      // Batch send up to 100 events per flush.
      final batch = _queue.take(100).toList();
      final body = jsonEncode({'events': batch.map((e) => e.toJson()).toList()});
      final ok = await _post(body);
      if (ok) {
        _queue.removeRange(0, batch.length);
        _totalSent += batch.length;
      } else {
        _totalFailed++;
      }
    } catch (_) {
      // ignore
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _post(String body) async {
    final url = _collectorUrl;
    if (url == null) return false;
    final uri = Uri.tryParse('$url/event');
    if (uri == null) return false;
    // Use raw Socket — dart:io HttpClient on iOS has been observed dropping
    // POST bodies in this app (Content-Length=0 in request hitting collector).
    // Workaround: write the HTTP/1.1 request manually over a TCP socket.
    Socket? sock;
    try {
      final host = uri.host;
      final port = uri.port == 0 ? 80 : uri.port;
      sock = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      final bodyBytes = utf8.encode(body);
      final reqLines = <String>[
        'POST ${uri.path}${uri.query.isNotEmpty ? '?${uri.query}' : ''} HTTP/1.1',
        'Host: $host:$port',
        'User-Agent: ai_debug/telemetry',
        'Content-Type: application/json; charset=utf-8',
        'Content-Length: ${bodyBytes.length}',
        'Connection: close',
        '',
        '',
      ];
      sock.add(utf8.encode(reqLines.join('\r\n')));
      sock.add(bodyBytes);
      await sock.flush().timeout(const Duration(seconds: 3));
      // Read response — at minimum the status line.
      final responseBuf = <int>[];
      try {
        await for (final chunk in sock.timeout(const Duration(seconds: 5))) {
          responseBuf.addAll(chunk);
          if (responseBuf.length > 1024) break; // status + headers fit
        }
      } catch (_) {/* timeout / disconnect */}
      final responseText = utf8.decode(responseBuf, allowMalformed: true);
      final statusLine = responseText.split('\r\n').firstWhere((l) => l.isNotEmpty, orElse: () => '');
      final m = RegExp(r'HTTP/\d\.\d (\d+)').firstMatch(statusLine);
      if (m == null) return false;
      final status = int.tryParse(m.group(1)!) ?? 0;
      return status >= 200 && status < 300;
    } catch (e) {
      _log.warning('telemetry post failed: $e');
      return false;
    } finally {
      try {
        sock?.destroy();
      } catch (_) {}
    }
  }

  Future<void> flushNow() async => _flush();
}

class _Event {
  final String kind;
  final int tsMs;
  final String tsIso;
  final String appId;
  final String isolate;
  final Map<String, dynamic> payload;
  _Event({
    required this.kind,
    required this.tsMs,
    required this.tsIso,
    required this.appId,
    required this.isolate,
    required this.payload,
  });
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'ts_ms': tsMs,
        'ts_iso': tsIso,
        'app_id': appId,
        'isolate': isolate,
        'payload': payload,
      };
}

class _Observer extends WidgetsBindingObserver {
  final Telemetry t;
  _Observer(this.t);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    t.emit(kind: 'lifecycle', payload: {'state': state.name});
  }

  @override
  void didChangeMetrics() {
    // skip — too chatty
  }
}
