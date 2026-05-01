import '../internal/telemetry.dart';
import '../registry.dart';

/// Telemetry control tools.
void registerTelemetryTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'telemetry_start',
    description:
        'Enable telemetry pusher: subscribes to Logger.root + lifecycle, '
        'POSTs events to <collectorUrl>/event. Idempotent.',
    inputSchema: AiDebugSchema.object(
      {
        'collectorUrl': AiDebugSchema.string(description: 'e.g. http://<collector-host>:9990'),
        'appId': AiDebugSchema.string(default_: 'ai_debug.app'),
        'isolate': AiDebugSchema.string(default_: 'main'),
      },
      required: ['collectorUrl'],
    ),
    handler: (args) async {
      Telemetry.I.start(
        collectorUrl: args['collectorUrl'] as String,
        appId: (args['appId'] as String?) ?? 'ai_debug.app',
        isolate: (args['isolate'] as String?) ?? 'main',
      );
      return {'ok': true, 'enabled': Telemetry.I.isEnabled, 'collectorUrl': Telemetry.I.collectorUrl};
    },
  ));

  registry.add(ToolEntry(
    name: 'telemetry_stop',
    description: 'Disable telemetry pusher.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      Telemetry.I.stop();
      return {'ok': true, 'enabled': Telemetry.I.isEnabled};
    },
  ));

  registry.add(ToolEntry(
    name: 'telemetry_status',
    description: 'Return telemetry pusher state: enabled, url, queue depth, totals.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {
      'enabled': Telemetry.I.isEnabled,
      'collectorUrl': Telemetry.I.collectorUrl,
      'stats': Telemetry.I.stats,
    },
  ));

  registry.add(ToolEntry(
    name: 'telemetry_emit',
    description: 'Manually emit a telemetry event (kind + payload).',
    inputSchema: AiDebugSchema.object(
      {
        'kind': AiDebugSchema.string(),
        'payload': AiDebugSchema.object({}),
      },
      required: ['kind'],
    ),
    handler: (args) async {
      Telemetry.I.emit(
        kind: args['kind'] as String,
        payload: (args['payload'] as Map?)?.cast<String, dynamic>(),
      );
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'telemetry_flush',
    description: 'Force-flush queued events to the collector now.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      await Telemetry.I.flushNow();
      return {'ok': true, 'remaining': Telemetry.I.queueDepth};
    },
  ));
}
