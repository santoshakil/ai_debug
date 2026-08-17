import 'dart:ui';

import 'package:flutter/scheduler.dart';

import 'bounded_buffer.dart';
import 'resource_monitor.dart' show WallClock;

typedef AddTimingsCallback = void Function(TimingsCallback callback);
typedef RemoveTimingsCallback = void Function(TimingsCallback callback);
typedef FrameContextReader = FrameContext Function();

class FrameContext {
  const FrameContext({
    required this.refreshRateHz,
    required this.viewCount,
    required this.displayCount,
  });

  final double refreshRateHz;
  final int viewCount;
  final int displayCount;
}

class FrameSample {
  const FrameSample({
    required this.sequence,
    required this.capturedAt,
    required this.frameNumber,
    required this.vsyncStartMicros,
    required this.buildMicros,
    required this.rasterMicros,
    required this.vsyncOverheadMicros,
    required this.totalSpanMicros,
    required this.layerCacheCount,
    required this.layerCacheBytes,
    required this.pictureCacheCount,
    required this.pictureCacheBytes,
    required this.refreshRateHz,
    required this.frameBudgetMicros,
    required this.viewCount,
    required this.displayCount,
  });

  factory FrameSample.fromTiming(
    FrameTiming timing, {
    required int sequence,
    required DateTime capturedAt,
    required FrameContext context,
  }) {
    final rate = _validRefreshRate(context.refreshRateHz);
    return FrameSample(
      sequence: sequence,
      capturedAt: capturedAt,
      frameNumber: timing.frameNumber,
      vsyncStartMicros: timing.timestampInMicroseconds(FramePhase.vsyncStart),
      buildMicros: timing.buildDuration.inMicroseconds,
      rasterMicros: timing.rasterDuration.inMicroseconds,
      vsyncOverheadMicros: timing.vsyncOverhead.inMicroseconds,
      totalSpanMicros: timing.totalSpan.inMicroseconds,
      layerCacheCount: timing.layerCacheCount,
      layerCacheBytes: timing.layerCacheBytes,
      pictureCacheCount: timing.pictureCacheCount,
      pictureCacheBytes: timing.pictureCacheBytes,
      refreshRateHz: rate,
      frameBudgetMicros: 1000000 / rate,
      viewCount: context.viewCount,
      displayCount: context.displayCount,
    );
  }

  final int sequence;
  final DateTime capturedAt;
  final int frameNumber;
  final int vsyncStartMicros;
  final int buildMicros;
  final int rasterMicros;
  final int vsyncOverheadMicros;
  final int totalSpanMicros;
  final int layerCacheCount;
  final int layerCacheBytes;
  final int pictureCacheCount;
  final int pictureCacheBytes;
  final double refreshRateHz;
  final double frameBudgetMicros;
  final int viewCount;
  final int displayCount;

  bool get missedUiFrame => buildMicros > frameBudgetMicros;
  bool get missedRasterFrame => rasterMicros > frameBudgetMicros;
  bool get highLatency => totalSpanMicros > frameBudgetMicros;
  bool get combinedWorkOverBudget =>
      buildMicros + rasterMicros > frameBudgetMicros;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'frameNumber': frameNumber,
    'vsyncStartMicros': vsyncStartMicros,
    'refreshRateHz': refreshRateHz,
    'frameBudgetMs': frameBudgetMicros / 1000,
    'buildMs': buildMicros / 1000,
    'rasterMs': rasterMicros / 1000,
    'vsyncOverheadMs': vsyncOverheadMicros / 1000,
    'totalSpanMs': totalSpanMicros / 1000,
    'missedUiFrame': missedUiFrame,
    'missedRasterFrame': missedRasterFrame,
    'highLatency': highLatency,
    'combinedWorkOverBudget': combinedWorkOverBudget,
    'rasterCache': {
      'layerCount': layerCacheCount,
      'layerBytes': layerCacheBytes,
      'pictureCount': pictureCacheCount,
      'pictureBytes': pictureCacheBytes,
    },
    'viewCountAtCapture': viewCount,
    'displayCountAtCapture': displayCount,
  };
}

class FrameMonitor {
  FrameMonitor({
    int capacity = 600,
    Duration idleAfter = const Duration(seconds: 2),
    AddTimingsCallback? addTimingsCallback,
    RemoveTimingsCallback? removeTimingsCallback,
    FrameContextReader? contextReader,
    WallClock? wallClock,
  }) : _samples = BoundedBuffer<FrameSample>(capacity),
       _idleAfter = idleAfter,
       _addTimingsCallback =
           addTimingsCallback ?? SchedulerBinding.instance.addTimingsCallback,
       _removeTimingsCallback =
           removeTimingsCallback ??
           SchedulerBinding.instance.removeTimingsCallback,
       _contextReader = contextReader ?? readFrameContext,
       _wallClock = wallClock ?? DateTime.now {
    if (idleAfter < Duration.zero) {
      throw ArgumentError.value(idleAfter, 'idleAfter', 'must not be negative');
    }
  }

  final BoundedBuffer<FrameSample> _samples;
  final Duration _idleAfter;
  final AddTimingsCallback _addTimingsCallback;
  final RemoveTimingsCallback _removeTimingsCallback;
  final FrameContextReader _contextReader;
  final WallClock _wallClock;

  late final TimingsCallback _callback = addTimings;
  int _sequence = 0;
  bool _running = false;
  bool _disposed = false;

  bool get isRunning => _running;
  bool get isDisposed => _disposed;
  int get capacity => _samples.capacity;
  int get droppedSamples => _samples.dropped;

  void start() {
    _checkActive();
    if (_running) return;
    _addTimingsCallback(_callback);
    _running = true;
  }

  void stop() {
    if (!_running) return;
    _removeTimingsCallback(_callback);
    _running = false;
  }

  void addTimings(List<FrameTiming> timings) {
    _checkActive();
    if (timings.isEmpty) return;
    final context = _contextReader();
    final capturedAt = _wallClock();
    for (final timing in timings) {
      _samples.add(
        FrameSample.fromTiming(
          timing,
          sequence: ++_sequence,
          capturedAt: capturedAt,
          context: context,
        ),
      );
    }
  }

  List<FrameSample> history({int? limit}) => _samples.tail(limit);

  Map<String, Object?> summary({int? limit}) {
    final frames = history(limit: limit);
    final latest = frames.isEmpty ? null : frames.last;
    final idle =
        latest == null ||
        _wallClock().difference(latest.capturedAt) > _idleAfter;
    final rates = frames.map((sample) => sample.refreshRateHz).toList();
    return {
      'source': 'flutter-frame-timing',
      'scope': 'all frame timings reported to the current Flutter engine',
      'running': isRunning,
      'idle': idle,
      'sampleCount': frames.length,
      'storedSampleCount': _samples.length,
      'capacity': capacity,
      'droppedSamples': droppedSamples,
      if (latest != null)
        'latestFrameAt': latest.capturedAt.toUtc().toIso8601String(),
      if (rates.isNotEmpty) ...{
        'targetRefreshRateHz': rates.last,
        'minObservedRefreshRateHz': rates.reduce((a, b) => a < b ? a : b),
        'maxObservedRefreshRateHz': rates.reduce((a, b) => a > b ? a : b),
      },
      'observedFrameRateFps': _throughput(frames),
      'misses': {
        'ui': frames.where((frame) => frame.missedUiFrame).length,
        'raster': frames.where((frame) => frame.missedRasterFrame).length,
        'highLatency': frames.where((frame) => frame.highLatency).length,
      },
      'combinedWorkOverBudget': frames
          .where((frame) => frame.combinedWorkOverBudget)
          .length,
      'build': _durationStats(frames.map((frame) => frame.buildMicros)),
      'raster': _durationStats(frames.map((frame) => frame.rasterMicros)),
      'totalSpan': _durationStats(frames.map((frame) => frame.totalSpanMicros)),
      'vsyncOverhead': _durationStats(
        frames.map((frame) => frame.vsyncOverheadMicros),
      ),
      if (latest != null)
        'latestRasterCache': {
          'layerCount': latest.layerCacheCount,
          'layerBytes': latest.layerCacheBytes,
          'pictureCount': latest.pictureCacheCount,
          'pictureBytes': latest.pictureCacheBytes,
        },
      'limits': const {
        'viewAttribution':
            'FrameTiming has no view id; multi-view frames cannot be separated.',
        'refreshRate':
            'The budget uses the implicit view display rate at callback time; multi-display frames may differ.',
        'combinedWork':
            'UI and raster threads are pipelined; their combined time is a workload signal, not a missed-frame count.',
        'fps':
            'Observed frame rate includes every gap between the first and last sampled frame; use idle to distinguish a stopped app.',
        'mode':
            'Use profile mode for performance evidence; debug mode adds large overhead.',
      },
    };
  }

  void clear() => _samples.clear();

  void dispose() {
    if (_disposed) return;
    stop();
    _samples.clear();
    _disposed = true;
  }

  void _checkActive() {
    if (_disposed) throw StateError('frame monitor is disposed');
  }
}

FrameContext readFrameContext() {
  final dispatcher = PlatformDispatcher.instance;
  final view = dispatcher.implicitView;
  return FrameContext(
    refreshRateHz: view?.display.refreshRate ?? 60,
    viewCount: dispatcher.views.length,
    displayCount: dispatcher.displays.length,
  );
}

double _validRefreshRate(double value) =>
    value.isFinite && value > 0 ? value : 60;

Map<String, Object?> _durationStats(Iterable<int> source) {
  final values = source.toList()..sort();
  if (values.isEmpty) {
    return const {
      'meanMs': null,
      'p50Ms': null,
      'p90Ms': null,
      'p95Ms': null,
      'p99Ms': null,
      'maxMs': null,
    };
  }
  final sum = values.fold<int>(0, (total, value) => total + value);
  double ms(num value) => value / 1000;
  return {
    'meanMs': ms(sum / values.length),
    'p50Ms': ms(_percentile(values, 0.50)),
    'p90Ms': ms(_percentile(values, 0.90)),
    'p95Ms': ms(_percentile(values, 0.95)),
    'p99Ms': ms(_percentile(values, 0.99)),
    'maxMs': ms(values.last),
  };
}

int _percentile(List<int> sorted, double percentile) {
  final index = (percentile * sorted.length).ceil().clamp(1, sorted.length) - 1;
  return sorted[index];
}

double? _throughput(List<FrameSample> samples) {
  if (samples.length < 2) return null;
  final elapsed =
      samples.last.vsyncStartMicros - samples.first.vsyncStartMicros;
  if (elapsed <= 0) return null;
  return (samples.length - 1) * Duration.microsecondsPerSecond / elapsed;
}
