import '../observability/network_monitor.dart';
import '../registry.dart';

NetworkMonitor? _monitor;

NetworkMonitor get networkMonitor => _monitor ??= NetworkMonitor();

void registerNetworkMonitorTools(
  CommandRegistry registry, {
  required bool controls,
}) {
  final monitor = networkMonitor;

  registry.add(
    ToolEntry(
      name: 'network.status',
      description: 'Summary of explicitly recorded app network requests.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => monitor.summary(),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'network.history',
      description:
          'Bounded history of explicitly recorded app network requests.',
      inputSchema: AiDebugSchema.object({
        'after': AiDebugSchema.integer(min: 0),
        'limit': AiDebugSchema.integer(min: 1, max: 1000, default_: 100),
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
          'limits': const {
            'coverage': 'Only requests recorded through AiDebug.trackNetwork.',
            'bodies': 'Request and response bodies are never stored.',
            'urls': 'User info, fragments, and query values are removed.',
          },
        };
      },
    ),
  );

  if (controls) {
    registry.add(
      ToolEntry(
        name: 'network.clear',
        description: 'Clear completed network request history.',
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

void disposeNetworkMonitorTools() {
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
