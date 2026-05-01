import 'package:logging/logging.dart';

import '../internal/bridge.dart';
import '../registry.dart';

/// Logger.root visibility + level control. The bridge already captures recent
/// LogRecords into AiDebug.tailLogs(); these tools surface the buffer + provide
/// level controls.
void registerLogTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'log_level_get',
    description: 'Read Logger.root.level.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {
      'level': Logger.root.level.name,
      'value': Logger.root.level.value,
    },
  ));

  registry.add(ToolEntry(
    name: 'log_level_set',
    description: 'Set Logger.root.level. ALL=0, FINEST=300, FINER=400, FINE=500, '
        'CONFIG=700, INFO=800, WARNING=900, SEVERE=1000, SHOUT=1200, OFF=2000.',
    inputSchema: AiDebugSchema.object(
      {
        'level': AiDebugSchema.string(
          enum_: [
            'ALL', 'FINEST', 'FINER', 'FINE', 'CONFIG',
            'INFO', 'WARNING', 'SEVERE', 'SHOUT', 'OFF',
          ],
        ),
      },
      required: ['level'],
    ),
    handler: (args) async {
      final lvl = args['level'] as String;
      const map = {
        'ALL': Level.ALL,
        'FINEST': Level.FINEST,
        'FINER': Level.FINER,
        'FINE': Level.FINE,
        'CONFIG': Level.CONFIG,
        'INFO': Level.INFO,
        'WARNING': Level.WARNING,
        'SEVERE': Level.SEVERE,
        'SHOUT': Level.SHOUT,
        'OFF': Level.OFF,
      };
      final l = map[lvl];
      if (l == null) {
        return {'ok': false, 'error': 'invalid level: $lvl'};
      }
      Logger.root.level = l;
      return {'ok': true, 'level': l.name};
    },
  ));

  registry.add(ToolEntry(
    name: 'log_tail',
    description:
        'Read most-recent records from the in-memory Dart log buffer (capacity ~2000). '
        'Independent of any drift/file persistence — purely live. Use this for fast inspection '
        'when DriftLogger is unavailable or during boot.',
    inputSchema: AiDebugSchema.object({
      'limit': AiDebugSchema.integer(default_: 200, min: 1, max: 2000),
      'minLevel': AiDebugSchema.string(
        enum_: ['ALL', 'FINEST', 'FINER', 'FINE', 'CONFIG', 'INFO', 'WARNING', 'SEVERE', 'SHOUT'],
      ),
      'grep': AiDebugSchema.string(),
    }),
    handler: (args) async {
      final limit = (args['limit'] as num?)?.toInt() ?? 200;
      final minLevelStr = args['minLevel'] as String?;
      final grep = args['grep'] as String?;
      Level? minLevel;
      if (minLevelStr != null) {
        const map = {
          'ALL': Level.ALL,
          'FINEST': Level.FINEST,
          'FINER': Level.FINER,
          'FINE': Level.FINE,
          'CONFIG': Level.CONFIG,
          'INFO': Level.INFO,
          'WARNING': Level.WARNING,
          'SEVERE': Level.SEVERE,
          'SHOUT': Level.SHOUT,
        };
        minLevel = map[minLevelStr];
      }
      final records = Bridge.I.logs
          .tail(limit: limit, minLevel: minLevel, grep: grep)
          .toList();
      return {
        'count': records.length,
        'records': records
            .map((r) => {
                  'when': r.time.toIso8601String(),
                  'whenMs': r.time.millisecondsSinceEpoch,
                  'level': r.level.name,
                  'logger': r.loggerName,
                  'message': r.message,
                  if (r.error != null) 'error': r.error.toString(),
                  if (r.stackTrace != null) 'stack': r.stackTrace.toString(),
                })
            .toList(),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'log_emit',
    description:
        'Emit a Logger record with arbitrary level, name, message. Useful for autonomous '
        'tests to mark events in the log timeline.',
    inputSchema: AiDebugSchema.object(
      {
        'level': AiDebugSchema.string(
          default_: 'INFO',
          enum_: ['FINEST', 'FINER', 'FINE', 'CONFIG', 'INFO', 'WARNING', 'SEVERE', 'SHOUT'],
        ),
        'name': AiDebugSchema.string(default_: 'ai_debug.test'),
        'message': AiDebugSchema.string(),
      },
      required: ['message'],
    ),
    handler: (args) async {
      final levelStr = (args['level'] as String?) ?? 'INFO';
      final loggerName = (args['name'] as String?) ?? 'ai_debug.test';
      final message = args['message'] as String;
      const map = {
        'FINEST': Level.FINEST,
        'FINER': Level.FINER,
        'FINE': Level.FINE,
        'CONFIG': Level.CONFIG,
        'INFO': Level.INFO,
        'WARNING': Level.WARNING,
        'SEVERE': Level.SEVERE,
        'SHOUT': Level.SHOUT,
      };
      final l = map[levelStr] ?? Level.INFO;
      Logger(loggerName).log(l, message);
      return {'ok': true};
    },
  ));
}
