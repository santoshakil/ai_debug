import '../observability/error_monitor.dart';
import '../registry.dart';

ErrorMonitor? _monitor;

ErrorMonitor get errorMonitor => _monitor ??= ErrorMonitor();

void registerErrorMonitorTools(
  CommandRegistry registry, {
  required bool controls,
}) {
  final monitor = errorMonitor..start();

  registry.add(
    ToolEntry(
      name: 'errors.status',
      description: 'Error monitor state and bounded-buffer counts.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'running': monitor.isStarted,
        'count': monitor.length,
        'capacity': monitor.capacity,
        'dropped': monitor.dropped,
        'sources': const ['flutter', 'platform', 'app'],
        'limits': const {
          'zones':
              'Only errors forwarded with AiDebug.recordError are included.',
          'isolates': 'Other isolates must forward errors explicitly.',
        },
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'errors.history',
      description: 'Recent Flutter, platform, and explicitly recorded errors.',
      inputSchema: AiDebugSchema.object({
        'after': AiDebugSchema.integer(min: 0),
        'limit': AiDebugSchema.integer(min: 1, max: 500, default_: 100),
      }),
      annotations: _readOnly,
      handler: (args) {
        final events = monitor.history(
          after: args['after'] as int?,
          limit: args['limit'] as int? ?? 100,
        );
        return {
          'count': events.length,
          'capacity': monitor.capacity,
          'dropped': monitor.dropped,
          'events': [for (final event in events) event.toJson()],
        };
      },
    ),
  );

  if (controls) {
    registry.add(
      ToolEntry(
        name: 'errors.clear',
        description: 'Clear the in-memory error history.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _control,
        handler: (_) {
          monitor.clear();
          return {'ok': true};
        },
      ),
    );
  }
}

void disposeErrorMonitorTools() {
  _monitor?.dispose();
  _monitor = null;
}

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': false,
};
