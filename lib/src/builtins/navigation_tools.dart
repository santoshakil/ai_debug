import '../navigation/navigation_adapter.dart';
import '../registry.dart';

NavigationAdapter? _adapter;

void setNavigationAdapter(NavigationAdapter? adapter) => _adapter = adapter;

void clearNavigationAdapter() => _adapter = null;

void registerNavigationTools(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'app.routes',
      description: 'Route state from the app navigation adapter.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => _required().read(),
    ),
  );
  registry.add(
    ToolEntry(
      name: 'app.navigate',
      description: 'Navigate through the app navigation adapter.',
      inputSchema: AiDebugSchema.object(
        {
          'location': AiDebugSchema.string(minLength: 1, maxLength: 2048),
          'arguments': AiDebugSchema.map(),
        },
        required: ['location'],
      ),
      annotations: _mutating,
      handler: (args) async => {
        'result': await _required().go(
          args['location'] as String,
          (args['arguments'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'app.back',
      description: 'Request back navigation through the app adapter.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _mutating,
      handler: (_) async => {'popped': await _required().pop()},
    ),
  );
  registry.add(
    ToolEntry(
      name: 'app.replace',
      description: 'Replace the current route through the app adapter.',
      inputSchema: AiDebugSchema.object(
        {
          'location': AiDebugSchema.string(minLength: 1, maxLength: 2048),
          'arguments': AiDebugSchema.map(),
        },
        required: ['location'],
      ),
      annotations: _mutating,
      handler: (args) async => {
        'result': await _required().replaceWith(
          args['location'] as String,
          (args['arguments'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'app.pop_until',
      description: 'Pop routes to a location through the app adapter.',
      inputSchema: AiDebugSchema.object(
        {'location': AiDebugSchema.string(minLength: 1, maxLength: 2048)},
        required: ['location'],
      ),
      annotations: _mutating,
      handler: (args) async => {
        'result': await _required().popTo(args['location'] as String),
      },
    ),
  );
}

NavigationAdapter _required() {
  final adapter = _adapter;
  if (adapter == null) {
    throw StateError('navigation adapter is not registered');
  }
  return adapter;
}

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _mutating = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': true,
};
