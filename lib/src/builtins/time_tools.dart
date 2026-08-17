import 'dart:io';

import 'package:flutter/scheduler.dart';

import '../registry.dart';

final _clockStartedAt = DateTime.now();
final _clockUptime = Stopwatch()..start();
double? _baselineDilation;
double? _ownedDilation;

void registerTimeTools(CommandRegistry registry, {required bool controls}) {
  registry.add(
    ToolEntry(
      name: 'runtime.clock',
      description:
          'Wall clock, monotonic ai_debug clock uptime, timezone, and PID.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) {
        final now = DateTime.now();
        return {
          'timestamp': now.toIso8601String(),
          'timestampUtc': now.toUtc().toIso8601String(),
          'timestampMs': now.millisecondsSinceEpoch,
          'monotonicUs': _clockUptime.elapsedMicroseconds,
          'clockStartedAt': _clockStartedAt.toIso8601String(),
          'timezone': now.timeZoneName,
          'timezoneOffsetMinutes': now.timeZoneOffset.inMinutes,
          'pid': pid,
          'timeDilation': timeDilation,
        };
      },
    ),
  );
  if (controls) {
    registry.add(
      ToolEntry(
        name: 'runtime.time_dilation',
        description: 'Set Flutter animation time dilation.',
        inputSchema: AiDebugSchema.object(
          {'factor': AiDebugSchema.number(min: 0.01, max: 100)},
          required: ['factor'],
        ),
        annotations: _control,
        handler: (args) {
          _baselineDilation ??= timeDilation;
          timeDilation = (args['factor'] as num).toDouble();
          _ownedDilation = timeDilation;
          return {'factor': timeDilation};
        },
      ),
    );
  }
}

void disposeTimeTools() {
  final baseline = _baselineDilation;
  final owned = _ownedDilation;
  _baselineDilation = null;
  _ownedDilation = null;
  if (baseline != null && owned != null && timeDilation == owned) {
    timeDilation = baseline;
  }
}

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': false,
};
