import '../registry.dart';

/// State inspector registry: map<name, getter>. Each entry auto-generates a
/// `dump_<name>` tool returning the getter's snapshot.
class StateInspectorRegistry {
  final Map<String, Future<Object?> Function()> _getters = {};

  bool add(String name, Future<Object?> Function() getter) {
    final fresh = !_getters.containsKey(name);
    _getters[name] = getter;
    return fresh;
  }

  bool remove(String name) => _getters.remove(name) != null;

  List<String> names() => _getters.keys.toList();

  Future<Object?> read(String name) async {
    final g = _getters[name];
    if (g == null) return null;
    return g();
  }
}

StateInspectorRegistry _inspectors = StateInspectorRegistry();
StateInspectorRegistry get stateInspectors => _inspectors;

/// Register the single `dump_state` tool and the `list_state_inspectors` meta
/// tool. Each state inspector registered via `AiDebug.registerStateInspector`
/// is accessible through `dump_state { name: 'foo' }` — we keep one tool
/// rather than N so MCP tool lists stay tidy.
void registerStateInspectorTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'dump_state',
    description:
        'Read a registered state inspector. Use list_state_inspectors to see registered names.',
    inputSchema: AiDebugSchema.object(
      {'name': AiDebugSchema.string(description: 'Inspector name, e.g. "auth" or "timeline".')},
      required: ['name'],
    ),
    handler: (args) async {
      final name = args['name'] as String;
      if (!_inspectors.names().contains(name)) {
        return {
          'ok': false,
          'error': 'no state inspector named "$name"',
          'available': _inspectors.names(),
        };
      }
      final value = await _inspectors.read(name);
      return {'ok': true, 'name': name, 'value': value};
    },
  ));

  registry.add(ToolEntry(
    name: 'list_state_inspectors',
    description: 'List all registered state inspector names.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {'inspectors': _inspectors.names()},
  ));
}
