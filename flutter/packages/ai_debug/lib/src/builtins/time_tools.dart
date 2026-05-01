import 'dart:io';

import 'package:flutter/scheduler.dart';

import '../registry.dart';

/// Process clock + monotonic + uptime tools.
final _processStart = DateTime.now();
final _bootStopwatch = Stopwatch()..start();

void registerTimeTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'time_now',
    description:
        'Wall + monotonic clocks + tz info. wallMs since epoch (millis), monotonicUs '
        '(microseconds since process start), iso8601, timezone offset minutes.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final now = DateTime.now();
      final epoch = now.millisecondsSinceEpoch;
      return {
        'wallMs': epoch,
        'wallSec': (epoch / 1000).floor(),
        'monotonicUs': _bootStopwatch.elapsedMicroseconds,
        'monotonicMs': _bootStopwatch.elapsedMilliseconds,
        'iso8601': now.toIso8601String(),
        'iso8601Utc': now.toUtc().toIso8601String(),
        'tzOffsetMinutes': now.timeZoneOffset.inMinutes,
        'tzName': now.timeZoneName,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'time_uptime',
    description:
        'Process uptime — boot time + ms elapsed. monotonicMs is the clock since the '
        'ai_debug Dart code first ran (close enough to app startup for most purposes).',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      return {
        'startedAt': _processStart.toIso8601String(),
        'startedAtMs': _processStart.millisecondsSinceEpoch,
        'uptimeMs': _bootStopwatch.elapsedMilliseconds,
        'uptimeSec': (_bootStopwatch.elapsedMilliseconds / 1000).floor(),
        'pid': pid,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'time_dilation_set',
    description:
        'Set Flutter\'s timeDilation factor (slows or speeds animations). 1.0 = normal, '
        '5.0 = 5x slower, 0.5 = 2x faster. Useful to debug animation glitches.',
    inputSchema: AiDebugSchema.object(
      {'factor': AiDebugSchema.number(min: 0.01, max: 100.0)},
      required: ['factor'],
    ),
    handler: (args) async {
      timeDilation = (args['factor'] as num).toDouble();
      return {'ok': true, 'timeDilation': timeDilation};
    },
  ));

  registry.add(ToolEntry(
    name: 'time_dilation_get',
    description: 'Read Flutter\'s current timeDilation factor.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {'timeDilation': timeDilation},
  ));
}
