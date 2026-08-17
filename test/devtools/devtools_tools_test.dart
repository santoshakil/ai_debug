import 'dart:convert';
import 'dart:ui';

import 'package:ai_debug/src/builtins/devtools_tools.dart';
import 'package:ai_debug/src/devtools/frame_monitor.dart';
import 'package:ai_debug/src/devtools/resource_monitor.dart';
import 'package:ai_debug/src/devtools/trace_recorder.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DevTools tools register and dispatch through one runtime', (
    tester,
  ) async {
    final registry = CommandRegistry();
    final runtime = DevToolsRuntime(
      resources: ResourceMonitor(probe: _reading),
      frames: FrameMonitor(
        addTimingsCallback: (_) {},
        removeTimingsCallback: (_) {},
      ),
      trace: TraceRecorder(traceClock: () => 10),
    );
    addTearDown(registry.dispose);
    addTearDown(runtime.dispose);

    expect(
      registerDevToolsTools(
        registry,
        runtime: runtime,
        startMonitors: false,
        controls: true,
      ),
      same(runtime),
    );
    expect(registry.get('devtools.capabilities'), isNotNull);
    expect(registry.get('devtools.resources.history'), isNotNull);
    expect(registry.get('devtools.frames.summary'), isNotNull);
    expect(registry.get('devtools.ui.layers'), isNotNull);
    expect(registry.get('devtools.ui.semantics'), isNotNull);
    expect(registry.get('devtools.trace.export_chrome'), isNotNull);

    final capabilities = _json(
      await registry.dispatch('devtools.capabilities', const {}),
    );
    expect(capabilities['vmService'], {
      'enabled': false,
      'connected': false,
      'source': 'Dart VM service WebSocket',
    });
    expect(() => jsonEncode(capabilities), returnsNormally);

    await registry.dispatch('devtools.trace.start', const {});
    final started = _json(
      await registry.dispatch('devtools.trace.span_start', {
        'name': 'remote-work',
      }),
    );
    final spanId = started['spanId']! as int;
    await registry.dispatch('devtools.trace.span_finish', {'span_id': spanId});
    final exported = _json(
      await registry.dispatch('devtools.trace.export_chrome', {'limit': 10}),
    );
    expect(exported['traceEvents'], hasLength(1));

    final resource = _json(
      await registry.dispatch('devtools.resources.sample', const {}),
    );
    expect(resource['sample'], isA<Map<String, Object?>>());
    expect(resource['limits'], contains('heap'));
    expect(runtime.resources.history(), isEmpty);
    expect(() => jsonEncode(resource), returnsNormally);

    await expectLater(
      registry.dispatch('devtools.trace.span_finish', {'span_id': 999}),
      throwsStateError,
    );
  });

  testWidgets('DevTools runtime disposal is idempotent', (tester) async {
    final runtime = DevToolsRuntime(
      resources: ResourceMonitor(probe: _reading),
      frames: FrameMonitor(
        addTimingsCallback: (_) {},
        removeTimingsCallback: (_) {},
      ),
    );
    await runtime.dispose();
    await runtime.dispose();

    expect(runtime.isDisposed, isTrue);
    expect(() => runtime.startRemoteSpan('late'), throwsStateError);
  });

  testWidgets('global runtime is recreated after disposal', (tester) async {
    final first = devToolsRuntime;
    await disposeDevToolsTools();
    expect(first.isDisposed, isTrue);

    final second = devToolsRuntime;
    expect(second, isNot(same(first)));
    await disposeDevToolsTools();
    expect(second.isDisposed, isTrue);
  });

  testWidgets('history defaults and destructive hints match handlers', (
    tester,
  ) async {
    final registry = CommandRegistry();
    final resources = ResourceMonitor(probe: _reading);
    final frames = FrameMonitor(
      addTimingsCallback: (_) {},
      removeTimingsCallback: (_) {},
    );
    final trace = TraceRecorder();
    final runtime = DevToolsRuntime(
      resources: resources,
      frames: frames,
      trace: trace,
    );
    addTearDown(registry.dispose);
    addTearDown(runtime.dispose);
    registerDevToolsTools(
      registry,
      runtime: runtime,
      startMonitors: false,
      controls: true,
    );
    for (var i = 0; i < 61; i++) {
      resources.sampleNow();
    }
    frames.addTimings([for (var i = 0; i < 121; i++) _timing(i * 16667)]);
    trace.start();
    for (var i = 0; i < 201; i++) {
      trace.instant('event');
    }

    expect(
      (_json(
            await registry.dispatch('devtools.resources.history', const {}),
          )['samples']!
          as List),
      hasLength(60),
    );
    expect(
      (_json(
            await registry.dispatch('devtools.frames.history', const {}),
          )['frames']!
          as List),
      hasLength(120),
    );
    expect(
      (_json(
            await registry.dispatch('devtools.trace.events', const {}),
          )['events']!
          as List),
      hasLength(200),
    );
    for (final name in [
      'devtools.resources.clear',
      'devtools.frames.clear',
      'devtools.trace.start',
      'devtools.trace.stop',
      'devtools.trace.clear',
    ]) {
      expect(
        registry.get(name)!.annotations?['destructiveHint'],
        isTrue,
        reason: name,
      );
    }
  });
}

Map<String, Object?> _json(AiDebugResult result) =>
    Map<String, Object?>.from(result.json! as Map<String, Object?>);

ResourceReading _reading() => const ResourceReading(
  rssBytes: 1,
  maxRssBytes: 2,
  imageCacheEntries: 3,
  imageCacheBytes: 4,
  liveImages: 5,
  pendingImages: 6,
  imageCacheLimitEntries: 7,
  imageCacheLimitBytes: 8,
  schedulerPhase: 'idle',
  transientCallbacks: 0,
  hasScheduledFrame: false,
  framesEnabled: true,
  viewCount: 1,
  displayCount: 1,
  refreshRatesHz: [60],
);

FrameTiming _timing(int vsyncStart) => FrameTiming(
  vsyncStart: vsyncStart,
  buildStart: vsyncStart + 100,
  buildFinish: vsyncStart + 1100,
  rasterStart: vsyncStart + 1200,
  rasterFinish: vsyncStart + 2200,
  rasterFinishWallTime: vsyncStart + 2200,
  layerCacheCount: 0,
  layerCacheBytes: 0,
  pictureCacheCount: 0,
  pictureCacheBytes: 0,
  frameNumber: vsyncStart,
);
