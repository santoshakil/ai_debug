import 'dart:convert';
import 'dart:ui';

import 'package:ai_debug/src/devtools/frame_monitor.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frame monitor uses the observed refresh budget', () {
    final monitor = FrameMonitor(
      capacity: 3,
      addTimingsCallback: (_) {},
      removeTimingsCallback: (_) {},
      contextReader: () =>
          const FrameContext(refreshRateHz: 120, viewCount: 2, displayCount: 1),
      wallClock: () => DateTime.utc(2026, 1, 2),
    );
    addTearDown(monitor.dispose);

    monitor.addTimings([
      _timing(0, buildMicros: 9000, rasterMicros: 4000, frameNumber: 1),
      _timing(8333, buildMicros: 4000, rasterMicros: 9000, frameNumber: 2),
      _timing(16666, buildMicros: 4000, rasterMicros: 3000, frameNumber: 3),
    ]);

    final samples = monitor.history();
    expect(samples.first.frameBudgetMicros, closeTo(8333.33, 0.01));
    expect(samples.first.missedUiFrame, isTrue);
    expect(samples.first.missedRasterFrame, isFalse);
    expect(samples[1].missedRasterFrame, isTrue);
    expect(samples.last.highLatency, isFalse);

    final summary = monitor.summary();
    expect(summary['targetRefreshRateHz'], 120);
    expect(summary['observedFrameRateFps'], closeTo(120, 0.1));
    expect(summary['misses'], {'ui': 1, 'raster': 1, 'highLatency': 2});
    expect(summary['combinedWorkOverBudget'], 2);
    expect(
      summary['limits'],
      containsPair('viewAttribution', contains('no view id')),
    );
    expect(() => jsonEncode(summary), returnsNormally);
  });

  test('frame callback lifecycle is idempotent and bounded', () {
    TimingsCallback? attached;
    var adds = 0;
    var removes = 0;
    final monitor = FrameMonitor(
      capacity: 1,
      addTimingsCallback: (callback) {
        adds++;
        attached = callback;
      },
      removeTimingsCallback: (callback) {
        removes++;
        expect(callback, same(attached));
      },
      contextReader: () => const FrameContext(
        refreshRateHz: double.nan,
        viewCount: 1,
        displayCount: 1,
      ),
    );

    monitor.start();
    monitor.start();
    expect(adds, 1);
    attached!([
      _timing(0, buildMicros: 1000, rasterMicros: 1000),
      _timing(16667, buildMicros: 1000, rasterMicros: 1000),
    ]);
    expect(monitor.history(), hasLength(1));
    expect(monitor.history().single.refreshRateHz, 60);
    expect(monitor.droppedSamples, 1);

    monitor.stop();
    monitor.stop();
    expect(removes, 1);
    monitor.start();
    monitor.stop();
    expect(adds, 2);
    expect(removes, 2);
    monitor.dispose();
    expect(monitor.start, throwsStateError);
  });
}

FrameTiming _timing(
  int vsyncStart, {
  required int buildMicros,
  required int rasterMicros,
  int frameNumber = 0,
}) {
  final buildStart = vsyncStart + 100;
  final buildFinish = buildStart + buildMicros;
  final rasterStart = buildFinish + 100;
  final rasterFinish = rasterStart + rasterMicros;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
    layerCacheCount: 2,
    layerCacheBytes: 3,
    pictureCacheCount: 4,
    pictureCacheBytes: 5,
    frameNumber: frameNumber,
  );
}
