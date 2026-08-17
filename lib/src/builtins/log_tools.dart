import 'package:logging/logging.dart';

import '../internal/bridge.dart';
import '../registry.dart';

Level? _baseline;
Level? _owned;

void registerLogTools(CommandRegistry registry, {required bool controls}) {
  registry.add(
    ToolEntry(
      name: 'logs.status',
      description: 'In-memory Dart log buffer state.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'count': Bridge.I.logs.length,
        'capacity': Bridge.I.logs.capacity,
        'bytes': Bridge.I.logs.bytes,
        'maxBytes': Bridge.I.logs.maxBytes,
        'dropped': Bridge.I.logs.dropped,
        'rootLevel': Logger.root.level.name,
        'scope': 'package:logging records emitted in this isolate',
      },
    ),
  );
  if (controls) {
    registry.add(
      ToolEntry(
        name: 'logs.level',
        description: 'Read or set the root package:logging level.',
        inputSchema: AiDebugSchema.object({
          'level': AiDebugSchema.string(enum_: _levels.keys.toList()),
        }),
        annotations: _control,
        handler: (args) {
          final name = args['level'] as String?;
          if (name != null) {
            _baseline ??= Logger.root.level;
            Logger.root.level = _levels[name]!;
            _owned = Logger.root.level;
          }
          return {
            'level': Logger.root.level.name,
            'value': Logger.root.level.value,
          };
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'logs.emit',
        description: 'Emit one bounded package:logging marker record.',
        inputSchema: AiDebugSchema.object(
          {
            'level': AiDebugSchema.string(
              enum_: _emittedLevels.keys.toList(),
              default_: 'INFO',
            ),
            'logger': AiDebugSchema.string(
              minLength: 1,
              maxLength: 256,
              default_: 'ai_debug.marker',
            ),
            'message': AiDebugSchema.string(minLength: 1, maxLength: 16384),
          },
          required: ['message'],
        ),
        annotations: _openWorld,
        handler: (args) {
          final level = _emittedLevels[args['level'] as String? ?? 'INFO']!;
          final name = args['logger'] as String? ?? 'ai_debug.marker';
          Logger(name).log(level, args['message'] as String);
          return {'ok': true, 'level': level.name, 'logger': name};
        },
      ),
    );
  }
  if (controls) {
    registry.add(
      ToolEntry(
        name: 'logs.clear',
        description: 'Clear the in-memory Dart log buffer.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _clear,
        handler: (_) {
          Bridge.I.logs.clear();
          return {'ok': true};
        },
      ),
    );
  }
}

void disposeLogTools() {
  final baseline = _baseline;
  final owned = _owned;
  _baseline = null;
  _owned = null;
  if (baseline != null && owned != null && Logger.root.level == owned) {
    Logger.root.level = baseline;
  }
}

const _levels = <String, Level>{
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

const _emittedLevels = <String, Level>{
  'FINEST': Level.FINEST,
  'FINER': Level.FINER,
  'FINE': Level.FINE,
  'CONFIG': Level.CONFIG,
  'INFO': Level.INFO,
  'WARNING': Level.WARNING,
  'SEVERE': Level.SEVERE,
  'SHOUT': Level.SHOUT,
};

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': false,
};

const _clear = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': false,
};

const _openWorld = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': true,
};
