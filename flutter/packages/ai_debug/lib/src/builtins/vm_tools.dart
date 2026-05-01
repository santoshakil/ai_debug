import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../registry.dart';

/// Dart VM / engine inspection: GC trigger, isolate id, frame timings, FPS.
void registerVmTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'vm_isolate_id',
    description: 'Current isolate name + debug id.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      return {
        'name': Isolate.current.debugName,
        'isolateId': developer.Service.getIsolateId(Isolate.current),
        'pid': pid,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'vm_force_gc',
    description:
        'Hint the Dart VM to GC. No guarantee — VM may decline. Useful when chasing '
        'memory leak symptoms before/after stress.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      // Allocate + drop a ton of small objects to encourage a major GC,
      // then yield so the GC scheduler can wake up.
      var sink = <List<int>>[];
      for (var i = 0; i < 4096; i++) {
        sink.add(List<int>.filled(1024, i));
      }
      // ignore: unused_local_variable
      final last = sink.last;
      sink = const [];
      await Future<void>.delayed(Duration.zero);
      return {'ok': true, 'note': 'best-effort GC hint, not guaranteed'};
    },
  ));

  registry.add(ToolEntry(
    name: 'vm_dart_version',
    description: 'Platform.version + executable path.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      return {
        'version': Platform.version,
        'executable': Platform.executable,
        'localeName': Platform.localeName,
        'numberOfProcessors': Platform.numberOfProcessors,
        'localHostname': Platform.localHostname,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'vm_frame_timings',
    description:
        'Subscribe to Flutter frame timings for a window of N frames and return summary: '
        'mean buildMs, mean rasterMs, max, jankFrames (>16ms), totalFrames.',
    inputSchema: AiDebugSchema.object({
      'frames': AiDebugSchema.integer(default_: 60, min: 1, max: 600),
      'timeoutMs': AiDebugSchema.integer(default_: 6000, min: 100, max: 60000),
    }),
    handler: (args) async {
      final wantFrames = (args['frames'] as num?)?.toInt() ?? 60;
      final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 6000;
      final samples = <FrameTiming>[];
      final completer = Completer<void>();
      late TimingsCallback cb;
      cb = (timings) {
        samples.addAll(timings);
        if (samples.length >= wantFrames && !completer.isCompleted) {
          completer.complete();
        }
      };
      WidgetsBinding.instance.addTimingsCallback(cb);
      try {
        // Force a few frames so the listener gets data.
        for (var i = 0; i < 4; i++) {
          WidgetsBinding.instance.scheduleFrame();
        }
        await completer.future.timeout(Duration(milliseconds: timeoutMs), onTimeout: () => null);
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(cb);
      }
      if (samples.isEmpty) {
        return {
          'ok': false,
          'error': 'no-frames',
          'note': 'app is idle / not animating — schedule_frame may help',
        };
      }
      var totalBuildUs = 0;
      var totalRasterUs = 0;
      var maxBuildUs = 0;
      var maxRasterUs = 0;
      var jank = 0;
      for (final s in samples) {
        final b = s.buildDuration.inMicroseconds;
        final r = s.rasterDuration.inMicroseconds;
        totalBuildUs += b;
        totalRasterUs += r;
        if (b > maxBuildUs) maxBuildUs = b;
        if (r > maxRasterUs) maxRasterUs = r;
        if (b + r > 16700) jank++;
      }
      return {
        'ok': true,
        'totalFrames': samples.length,
        'meanBuildMs': totalBuildUs / 1000.0 / samples.length,
        'meanRasterMs': totalRasterUs / 1000.0 / samples.length,
        'maxBuildMs': maxBuildUs / 1000.0,
        'maxRasterMs': maxRasterUs / 1000.0,
        'jankFrames': jank,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'vm_schedule_frame',
    description: 'Force the engine to schedule one frame. Useful before reading frame timings.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      WidgetsBinding.instance.scheduleFrame();
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'vm_microtask_yield',
    description:
        'Drain Dart microtasks by awaiting Future.delayed(Duration.zero) in a loop. '
        'Returns iterations completed inside maxMs window. Mostly diagnostic.',
    inputSchema: AiDebugSchema.object({
      'maxMs': AiDebugSchema.integer(default_: 100, min: 1, max: 5000),
    }),
    handler: (args) async {
      final maxMs = (args['maxMs'] as num?)?.toInt() ?? 100;
      final sw = Stopwatch()..start();
      var n = 0;
      while (sw.elapsedMilliseconds < maxMs) {
        await Future<void>.delayed(Duration.zero);
        n++;
      }
      sw.stop();
      return {'iterations': n, 'elapsedMs': sw.elapsedMilliseconds};
    },
  ));
}
