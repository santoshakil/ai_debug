import '../observability/lifecycle_monitor.dart';
import '../registry.dart';

LifecycleMonitor? _monitor;

LifecycleMonitor get lifecycleMonitor => _monitor ??= LifecycleMonitor();

void registerObserverTools(CommandRegistry registry, {required bool controls}) {
  final monitor = lifecycleMonitor..start();
  registry.add(
    ToolEntry(
      name: 'app.lifecycle',
      description: 'Current Flutter app lifecycle state.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'state': monitor.current?.name,
        'running': monitor.isStarted,
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'app.lifecycle_history',
      description: 'Recent Flutter app lifecycle changes.',
      inputSchema: AiDebugSchema.object({
        'after': AiDebugSchema.integer(min: 0),
        'limit': AiDebugSchema.integer(min: 1, max: 256, default_: 64),
      }),
      annotations: _readOnly,
      handler: (args) {
        final events = monitor.history(
          after: args['after'] as int?,
          limit: args['limit'] as int? ?? 64,
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
        name: 'app.lifecycle_clear',
        description: 'Clear app lifecycle history.',
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

void disposeObserverTools() {
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
