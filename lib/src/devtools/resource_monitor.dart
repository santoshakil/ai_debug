import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'bounded_buffer.dart';

typedef ResourceProbe = ResourceReading Function();
typedef WallClock = DateTime Function();
typedef MonotonicClock = int Function();

class ResourceReading {
  const ResourceReading({
    required this.rssBytes,
    required this.maxRssBytes,
    required this.imageCacheEntries,
    required this.imageCacheBytes,
    required this.liveImages,
    required this.pendingImages,
    required this.imageCacheLimitEntries,
    required this.imageCacheLimitBytes,
    required this.schedulerPhase,
    required this.transientCallbacks,
    required this.hasScheduledFrame,
    required this.framesEnabled,
    required this.viewCount,
    required this.displayCount,
    required this.refreshRatesHz,
  });

  final int rssBytes;
  final int maxRssBytes;
  final int imageCacheEntries;
  final int imageCacheBytes;
  final int liveImages;
  final int pendingImages;
  final int imageCacheLimitEntries;
  final int imageCacheLimitBytes;
  final String schedulerPhase;
  final int transientCallbacks;
  final bool hasScheduledFrame;
  final bool framesEnabled;
  final int viewCount;
  final int displayCount;
  final List<double> refreshRatesHz;
}

class ResourceSample {
  const ResourceSample({
    required this.sequence,
    required this.capturedAt,
    required this.monotonicMicros,
    required this.timerLagMicros,
    required this.reading,
  });

  final int sequence;
  final DateTime capturedAt;
  final int monotonicMicros;
  final int timerLagMicros;
  final ResourceReading reading;

  Map<String, Object?> toJson({bool includeSequence = true}) => {
    if (includeSequence) 'sequence': sequence,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'monotonicMicros': monotonicMicros,
    'timerLagMicros': timerLagMicros,
    'process': {
      'rssBytes': reading.rssBytes,
      'maxRssBytes': reading.maxRssBytes,
    },
    'flutter': {
      'imageCache': {
        'entries': reading.imageCacheEntries,
        'bytes': reading.imageCacheBytes,
        'liveImages': reading.liveImages,
        'pendingImages': reading.pendingImages,
        'limitEntries': reading.imageCacheLimitEntries,
        'limitBytes': reading.imageCacheLimitBytes,
      },
      'scheduler': {
        'phase': _cut(reading.schedulerPhase, 256),
        'transientCallbacks': reading.transientCallbacks,
        'hasScheduledFrame': reading.hasScheduledFrame,
        'framesEnabled': reading.framesEnabled,
      },
      'viewCount': reading.viewCount,
      'displayCount': reading.displayCount,
      'refreshRatesHz': [
        for (final rate in reading.refreshRatesHz.take(64))
          rate.isFinite ? rate : null,
      ],
      'refreshRatesTruncated': reading.refreshRatesHz.length > 64,
    },
  };
}

class ResourceMonitor {
  ResourceMonitor({
    this.interval = const Duration(seconds: 1),
    int capacity = 300,
    ResourceProbe? probe,
    WallClock? wallClock,
    MonotonicClock? monotonicClock,
  }) : _samples = BoundedBuffer<ResourceSample>(capacity),
       _probe = probe ?? readProcessResources,
       _wallClock = wallClock ?? DateTime.now,
       _monotonicClock = monotonicClock ?? _stopwatchMicros {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
  }

  static final Stopwatch _stopwatch = Stopwatch()..start();

  final Duration interval;
  final BoundedBuffer<ResourceSample> _samples;
  final ResourceProbe _probe;
  final WallClock _wallClock;
  final MonotonicClock _monotonicClock;

  Timer? _timer;
  int _sequence = 0;
  int? _lastTickMicros;
  String? _lastError;
  bool _disposed = false;

  bool get isRunning => _timer != null;
  bool get isDisposed => _disposed;
  int get capacity => _samples.capacity;
  int get droppedSamples => _samples.dropped;
  String? get lastError => _lastError;
  ResourceSample? get latest => _samples.lastOrNull;

  void start({bool sampleImmediately = true}) {
    _checkActive();
    if (isRunning) return;
    _lastTickMicros = _monotonicClock();
    if (sampleImmediately) sampleNow();
    _timer = Timer.periodic(interval, _onTick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastTickMicros = null;
  }

  ResourceSample sampleNow({int timerLagMicros = 0}) {
    _checkActive();
    final sample = ResourceSample(
      sequence: ++_sequence,
      capturedAt: _wallClock(),
      monotonicMicros: _monotonicClock(),
      timerLagMicros: math.max(0, timerLagMicros),
      reading: _probe(),
    );
    _samples.add(sample);
    _lastError = null;
    return sample;
  }

  Map<String, Object?> inspectNow() {
    _checkActive();
    return {
      ...ResourceSample(
        sequence: _sequence,
        capturedAt: _wallClock(),
        monotonicMicros: _monotonicClock(),
        timerLagMicros: 0,
        reading: _probe(),
      ).toJson(includeSequence: false),
      'stored': false,
    };
  }

  List<ResourceSample> history({int? limit}) => _samples.tail(limit);

  Map<String, Object?> status() => {
    'source': 'app-process',
    'scope': 'current process and current Flutter engine',
    'running': isRunning,
    'intervalMs': interval.inMilliseconds,
    'capacity': capacity,
    'sampleCount': _samples.length,
    'droppedSamples': droppedSamples,
    if (_lastError != null) 'lastError': _lastError,
    if (latest != null) 'latest': latest!.toJson(),
    'limits': const {
      'rss': 'Whole-process resident memory; it is not Dart heap usage.',
      'cpu': 'CPU usage requires VM service, native, or host tooling.',
      'heap': 'Dart heap, allocations, and GC require VM service.',
      'native':
          'GPU, thermal, battery, and native heap are not available here.',
    },
  };

  void clear() => _samples.clear();

  void dispose() {
    if (_disposed) return;
    stop();
    _samples.clear();
    _disposed = true;
  }

  void _onTick(Timer _) {
    final now = _monotonicClock();
    final previous = _lastTickMicros ?? now;
    _lastTickMicros = now;
    final lag = now - previous - interval.inMicroseconds;
    try {
      sampleNow(timerLagMicros: lag);
    } catch (error) {
      _lastError = _errorText(error);
    }
  }

  void _checkActive() {
    if (_disposed) throw StateError('resource monitor is disposed');
  }

  static int _stopwatchMicros() => _stopwatch.elapsedMicroseconds;
}

String _errorText(Object error) {
  try {
    return _cut(error.toString(), 4096);
  } catch (_) {
    return '<unavailable>';
  }
}

ResourceReading readProcessResources() {
  final cache = PaintingBinding.instance.imageCache;
  final scheduler = SchedulerBinding.instance;
  final dispatcher = ui.PlatformDispatcher.instance;
  final rss = ProcessInfo.currentRss;
  final maxRss = ProcessInfo.maxRss;
  return ResourceReading(
    rssBytes: rss,
    maxRssBytes: maxRss,
    imageCacheEntries: cache.currentSize,
    imageCacheBytes: cache.currentSizeBytes,
    liveImages: cache.liveImageCount,
    pendingImages: cache.pendingImageCount,
    imageCacheLimitEntries: cache.maximumSize,
    imageCacheLimitBytes: cache.maximumSizeBytes,
    schedulerPhase: scheduler.schedulerPhase.name,
    transientCallbacks: scheduler.transientCallbackCount,
    hasScheduledFrame: scheduler.hasScheduledFrame,
    framesEnabled: scheduler.framesEnabled,
    viewCount: dispatcher.views.length,
    displayCount: dispatcher.displays.length,
    refreshRatesHz: List<double>.unmodifiable(
      dispatcher.displays.map((display) => display.refreshRate),
    ),
  );
}

String _cut(String value, int maxLength) =>
    value.length <= maxLength ? value : '${value.substring(0, maxLength - 1)}…';
