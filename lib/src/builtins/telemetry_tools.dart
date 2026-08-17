import '../internal/telemetry.dart';
import '../registry.dart';

void registerTelemetryTools(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'telemetry.start',
      description: 'Start bounded opt-in HTTP telemetry forwarding.',
      inputSchema: AiDebugSchema.object(
        {
          'collectorUrl': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'appId': AiDebugSchema.string(minLength: 1, maxLength: 128),
          'isolate': AiDebugSchema.string(
            default_: 'main',
            minLength: 1,
            maxLength: 128,
          ),
        },
        required: ['collectorUrl', 'appId'],
      ),
      annotations: _openWorld,
      handler: (args) {
        Telemetry.I.start(
          collectorUrl: args['collectorUrl'] as String,
          appId: args['appId'] as String,
          isolate: args['isolate'] as String? ?? 'main',
        );
        return {'enabled': true};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'telemetry.stop',
      description: 'Stop telemetry forwarding.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _destructive,
      handler: (_) async {
        await Telemetry.I.stop();
        return {'enabled': false};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'telemetry.status',
      description: 'Telemetry forwarding state and bounded queue counts.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'enabled': Telemetry.I.isEnabled,
        'queue': Telemetry.I.stats,
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'telemetry.emit',
      description:
          'Add an explicit event after telemetry.start; periodic flushes can send it to the collector.',
      inputSchema: AiDebugSchema.object(
        {
          'kind': AiDebugSchema.string(minLength: 1, maxLength: 128),
          'payload': AiDebugSchema.map(),
        },
        required: ['kind'],
      ),
      annotations: _openWorld,
      handler: (args) {
        Telemetry.I.emit(
          kind: args['kind'] as String,
          payload: (args['payload'] as Map?)?.cast<String, dynamic>(),
        );
        return {'queued': Telemetry.I.queueDepth};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'telemetry.flush',
      description: 'Flush queued telemetry events now.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _destructiveOpenWorld,
      handler: (_) async {
        await Telemetry.I.flushNow();
        return {'remaining': Telemetry.I.queueDepth};
      },
    ),
  );
}

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _openWorld = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': true,
};

const _destructive = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': false,
};

const _destructiveOpenWorld = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': true,
};
