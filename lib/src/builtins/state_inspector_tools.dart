import '../registry.dart';
import '../state/state_registry.dart';

StateRegistry? _registry;
final _sources = <String, StateSource>{};

StateRegistry get stateInspectors {
  final active = _registry;
  if (active != null) return active;
  final next = StateRegistry();
  try {
    for (final source in _sources.values) {
      next.add(source);
    }
  } catch (_) {
    next.dispose().ignore();
    rethrow;
  }
  return _registry = next;
}

void addStateInspectorSource(StateSource source) {
  _validateSource(source);
  if (_sources.containsKey(source.name)) {
    throw StateError('state source already registered: ${source.name}');
  }
  _registry?.add(source);
  _sources[source.name] = source;
}

Future<bool> removeStateInspectorSource(String name) async {
  if (_sources.remove(name) == null) return false;
  await _registry?.remove(name);
  return true;
}

Future<void> clearStateInspectorSources() async {
  _sources.clear();
  await _registry?.dispose();
}

void registerStateInspectorTools(
  CommandRegistry registry, {
  required bool controls,
}) {
  final states = stateInspectors;
  registry.add(
    ToolEntry(
      name: 'state.sources',
      description: 'Registered app state sources and their status.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'count': states.length,
        'sources': [for (final source in states.sources) source.toJson()],
        'scope': 'Only state sources registered by the app are included.',
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'state.snapshot',
      description: 'Read one registered app state source.',
      inputSchema: AiDebugSchema.object(
        {'name': AiDebugSchema.string(minLength: 1, maxLength: 128)},
        required: ['name'],
      ),
      annotations: _readOnly,
      handler: (args) async =>
          (await states.read(args['name'] as String)).toJson(),
    ),
  );
  registry.add(
    ToolEntry(
      name: 'state.history',
      description: 'Recent changes from registered app state sources.',
      inputSchema: AiDebugSchema.object({
        'name': AiDebugSchema.string(minLength: 1, maxLength: 128),
        'after': AiDebugSchema.integer(min: 0),
        'limit': AiDebugSchema.integer(min: 1, max: 1000, default_: 100),
      }),
      annotations: _readOnly,
      handler: (args) {
        final events = states.history(
          name: args['name'] as String?,
          after: args['after'] as int?,
          limit: args['limit'] as int? ?? 100,
        );
        return {
          'count': events.length,
          'capacity': states.capacity,
          'dropped': states.dropped,
          'events': [for (final event in events) event.toJson()],
        };
      },
    ),
  );
  if (controls) {
    registry.add(
      ToolEntry(
        name: 'state.clear',
        description: 'Clear recorded state changes.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _control,
        handler: (_) {
          states.clearHistory();
          return {'ok': true};
        },
      ),
    );
  }
}

Future<void> disposeStateInspectors() async {
  final active = _registry;
  _registry = null;
  await active?.dispose();
}

void _validateSource(StateSource source) {
  if (source.name.isEmpty ||
      source.name.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(source.name)) {
    throw ArgumentError.value(source.name, 'name', 'invalid state source name');
  }
  if (source.timeout <= Duration.zero) {
    throw ArgumentError.value(source.timeout, 'timeout', 'must be positive');
  }
  if (source.changes != null && source.changesFactory != null) {
    throw ArgumentError('pass changes or changesFactory, not both');
  }
  if (source.changes != null && !source.changes!.isBroadcast) {
    throw ArgumentError.value(
      source.changes,
      'changes',
      'must be broadcast; use changesFactory for single-subscription streams',
    );
  }
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
