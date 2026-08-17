import 'dart:convert';

import 'package:ai_debug/src/devtools/resource_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resource history is bounded and reports its scope', () {
    var rss = 100;
    var monotonic = 0;
    final monitor = ResourceMonitor(
      capacity: 2,
      probe: () => _reading(rss++),
      wallClock: () => DateTime.utc(2026, 1, 2),
      monotonicClock: () => monotonic += 100,
    );
    addTearDown(monitor.dispose);

    monitor.sampleNow();
    monitor.sampleNow(timerLagMicros: -1);
    monitor.sampleNow(timerLagMicros: 50);

    final inspected = monitor.inspectNow();

    final history = monitor.history();
    expect(history.map((sample) => sample.sequence), [2, 3]);
    expect(history.last.timerLagMicros, 50);
    expect(monitor.droppedSamples, 1);
    expect(monitor.history(limit: 1).single.reading.rssBytes, 102);
    expect(inspected['stored'], isFalse);
    expect(inspected, isNot(contains('sequence')));
    expect(monitor.history(), hasLength(2));

    final status = monitor.status();
    expect(status['source'], 'app-process');
    expect(status['scope'], contains('current process'));
    expect(status['limits'], containsPair('heap', contains('VM service')));
    expect(() => jsonEncode(status), returnsNormally);
  });

  test('resource monitor start stop and dispose are clean', () {
    final monitor = ResourceMonitor(
      interval: const Duration(days: 1),
      probe: () => _reading(1),
      monotonicClock: () => 0,
    );

    monitor.start(sampleImmediately: false);
    monitor.start(sampleImmediately: false);
    expect(monitor.isRunning, isTrue);
    monitor.stop();
    monitor.stop();
    expect(monitor.isRunning, isFalse);
    monitor.start(sampleImmediately: false);
    expect(monitor.isRunning, isTrue);
    monitor.stop();

    monitor.dispose();
    monitor.dispose();
    expect(monitor.isDisposed, isTrue);
    expect(monitor.start, throwsStateError);
    expect(monitor.sampleNow, throwsStateError);
    expect(monitor.inspectNow, throwsStateError);
  });

  test('resource limits reject unbounded configurations', () {
    expect(() => ResourceMonitor(capacity: 0), throwsRangeError);
    expect(() => ResourceMonitor(interval: Duration.zero), throwsArgumentError);
  });

  test('resource samples sanitize display rates for JSON', () {
    final sample = ResourceSample(
      sequence: 1,
      capturedAt: DateTime.utc(2026),
      monotonicMicros: 1,
      timerLagMicros: 0,
      reading: ResourceReading(
        rssBytes: 1,
        maxRssBytes: 2,
        imageCacheEntries: 0,
        imageCacheBytes: 0,
        liveImages: 0,
        pendingImages: 0,
        imageCacheLimitEntries: 0,
        imageCacheLimitBytes: 0,
        schedulerPhase: 'x' * 300,
        transientCallbacks: 0,
        hasScheduledFrame: false,
        framesEnabled: true,
        viewCount: 70,
        displayCount: 70,
        refreshRatesHz: [double.nan, ...List.filled(69, 60)],
      ),
    );

    final json = sample.toJson();
    final flutter = json['flutter']! as Map<String, Object?>;
    expect(flutter['refreshRatesHz'], hasLength(64));
    expect(flutter['refreshRatesTruncated'], isTrue);
    expect(() => jsonEncode(json), returnsNormally);
  });

  test('timer probe error text cannot escape the monitor', () async {
    final monitor = ResourceMonitor(
      interval: const Duration(milliseconds: 1),
      probe: () => throw _BadText(),
      monotonicClock: () => 0,
    );
    monitor.start(sampleImmediately: false);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    monitor.stop();

    expect(monitor.status()['lastError'], '<unavailable>');
    monitor.dispose();
  });
}

ResourceReading _reading(int rss) => ResourceReading(
  rssBytes: rss,
  maxRssBytes: rss + 1,
  imageCacheEntries: 2,
  imageCacheBytes: 3,
  liveImages: 4,
  pendingImages: 5,
  imageCacheLimitEntries: 6,
  imageCacheLimitBytes: 7,
  schedulerPhase: 'idle',
  transientCallbacks: 8,
  hasScheduledFrame: false,
  framesEnabled: true,
  viewCount: 1,
  displayCount: 1,
  refreshRatesHz: const [120],
);

class _BadText {
  @override
  String toString() => throw StateError('no text');
}
