import '../isolates/isolate_hub.dart';
import '../registry.dart';

IsolateHub? _hub;

IsolateHub get isolateHub => _hub ??= IsolateHub();

void registerIsolateTools(CommandRegistry registry, {required bool controls}) {
  final hub = isolateHub;
  hub.start();
  registry.add(
    ToolEntry(
      name: 'isolates.status',
      description: 'Cooperating app isolates attached to the ai_debug hub.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'count': hub.isolates().length,
        'isolates': [
          for (final isolate in hub.isolates()) isolate.toJson(hub.staleAfter),
        ],
        'scope':
            'Only isolates attached with AiDebugIsolateClient are included.',
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'isolates.events',
      description: 'Bounded events forwarded by cooperating app isolates.',
      inputSchema: AiDebugSchema.object({
        'after': AiDebugSchema.integer(min: 0),
        'limit': AiDebugSchema.integer(min: 1, max: 1000, default_: 100),
      }),
      annotations: _readOnly,
      handler: (args) {
        final events = hub.history(
          after: args['after'] as int?,
          limit: args['limit'] as int? ?? 100,
        );
        return {
          'count': events.length,
          'capacity': hub.capacity,
          'dropped': hub.dropped,
          'events': [for (final event in events) event.toJson()],
        };
      },
    ),
  );
  if (controls) {
    registry.add(
      ToolEntry(
        name: 'isolates.clear',
        description: 'Clear forwarded isolate events.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _control,
        handler: (_) {
          hub.clear();
          return {'ok': true};
        },
      ),
    );
  }
}

Future<void> disposeIsolateTools() async {
  await _hub?.dispose();
  _hub = null;
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
