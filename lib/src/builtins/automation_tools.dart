import 'dart:async';

import '../automation/controller.dart';
import '../automation/models.dart';
import '../registry.dart';

UiAutomationController? _automation;

UiAutomationController? get automationController => _automation;

void registerAutomationTools(
  CommandRegistry registry, {
  UiAutomationConfig config = const UiAutomationConfig(),
}) {
  final previous = _automation;
  if (previous != null) unawaited(previous.dispose());
  final automation = UiAutomationController(config: config);
  _automation = automation;
  final limits = config.limits;
  final gestureMaxMs = limits.maxGesture.inMilliseconds;
  final dragDurationDefault = gestureMaxMs < 200 ? gestureMaxMs : 200;
  final pinchDurationDefault = gestureMaxMs < 240 ? gestureMaxMs : 240;
  final longPressDefault = gestureMaxMs < 600 ? gestureMaxMs : 600;
  final waitMaxMs = limits.maxWait.inMilliseconds;
  final waitDefault = waitMaxMs < 8000 ? waitMaxMs : 8000;
  final scrollWaitDefault = waitMaxMs < 10000 ? waitMaxMs : 10000;
  final scrollDefault = limits.maxScrolls < 10 ? limits.maxScrolls : 10;
  final selectorSchema = _selectorSchema(limits.maxStringLength);
  final doubleTapIntervalMax = gestureMaxMs - 80 < 250
      ? gestureMaxMs - 80
      : 250;
  final doubleTapIntervalDefault = doubleTapIntervalMax < 80
      ? doubleTapIntervalMax
      : 80;

  registry.add(
    ToolEntry(
      name: 'ui.capabilities',
      title: 'UI automation capabilities',
      description:
          'Report enabled UI automation permissions, hard limits, and platform limits.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => automation.capabilities(),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.snapshot',
      title: 'UI semantics snapshot',
      description:
          'Read visible Flutter semantics nodes with per-view logical geometry, actions, state, and redacted field values.',
      inputSchema: AiDebugSchema.object({
        'max_nodes': AiDebugSchema.integer(
          min: 1,
          max: limits.maxNodes,
          default_: limits.maxNodes,
        ),
        'max_string_length': AiDebugSchema.integer(
          min: 1,
          max: limits.maxStringLength,
          default_: limits.maxStringLength,
        ),
      }),
      annotations: _readOnly,
      handler: _tool(
        (args) => automation.snapshot(
          maxNodes: args['max_nodes'] as int?,
          maxStringLength: args['max_string_length'] as int?,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.find',
      title: 'Find UI nodes',
      description:
          'Find visible semantics nodes. Actions reject zero or multiple matches instead of choosing one silently.',
      inputSchema: AiDebugSchema.object(
        {
          'selector': selectorSchema,
          'limit': AiDebugSchema.integer(min: 1, max: 100, default_: 20),
        },
        required: ['selector'],
      ),
      annotations: _readOnly,
      handler: _tool(
        (args) => automation.find(
          _selector(args),
          limit: (args['limit'] as int?) ?? 20,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.activate',
      title: 'Perform a semantics action',
      description:
          'Perform one advertised Flutter semantics action on exactly one visible, enabled target.',
      inputSchema: _activateSchema(selectorSchema),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.activate(
          _selector(args),
          args['action'] as String,
          text: args['text'] as String?,
          base: args['base'] as int?,
          extent: args['extent'] as int?,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.tap',
      title: 'Tap a UI target',
      description:
          'Dispatch one bounded Flutter touch sequence at the center of exactly one visible tappable semantics node.',
      inputSchema: AiDebugSchema.object(
        {'selector': selectorSchema},
        required: ['selector'],
      ),
      annotations: _mutating,
      handler: _tool((args) => automation.tap(_selector(args))),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.double_tap',
      title: 'Double tap a UI target',
      description:
          'Dispatch two bounded Flutter taps at the center of exactly one visible semantics node.',
      inputSchema: AiDebugSchema.object(
        {
          'selector': selectorSchema,
          'interval_ms': AiDebugSchema.integer(
            min: 40,
            max: doubleTapIntervalMax,
            default_: doubleTapIntervalDefault,
          ),
        },
        required: ['selector'],
      ),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.doubleTap(
          _selector(args),
          interval: Duration(
            milliseconds:
                (args['interval_ms'] as int?) ?? doubleTapIntervalDefault,
          ),
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.long_press',
      title: 'Long press a UI target',
      description:
          'Hold one Flutter touch at a unique target center, or at explicit logical coordinates when allowed.',
      inputSchema: AiDebugSchema.oneOf([
        AiDebugSchema.object(
          {
            'selector': selectorSchema,
            'hold_ms': AiDebugSchema.integer(
              min: 1,
              max: gestureMaxMs,
              default_: longPressDefault,
            ),
          },
          required: const ['selector'],
        ),
        AiDebugSchema.object(
          {
            'view_id': AiDebugSchema.integer(min: 0),
            'x': AiDebugSchema.number(),
            'y': AiDebugSchema.number(),
            'hold_ms': AiDebugSchema.integer(
              min: 1,
              max: gestureMaxMs,
              default_: longPressDefault,
            ),
          },
          required: const ['view_id', 'x', 'y'],
        ),
      ]),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.longPress(
          selector: _optionalSelector(args),
          viewId: args['view_id'] as int?,
          x: (args['x'] as num?)?.toDouble(),
          y: (args['y'] as num?)?.toDouble(),
          hold: Duration(
            milliseconds: (args['hold_ms'] as int?) ?? longPressDefault,
          ),
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.drag',
      title: 'Drag in the Flutter view',
      description:
          'Dispatch a timed touch drag from a unique target center, or from explicit logical coordinates when allowed.',
      inputSchema: AiDebugSchema.oneOf([
        AiDebugSchema.object(
          {
            'selector': selectorSchema,
            'dx': AiDebugSchema.number(),
            'dy': AiDebugSchema.number(),
            'duration_ms': AiDebugSchema.integer(
              min: 1,
              max: gestureMaxMs,
              default_: dragDurationDefault,
            ),
            'steps': AiDebugSchema.integer(min: 1, max: 120, default_: 12),
          },
          required: const ['selector', 'dx', 'dy'],
        ),
        AiDebugSchema.object(
          {
            'view_id': AiDebugSchema.integer(min: 0),
            'x': AiDebugSchema.number(),
            'y': AiDebugSchema.number(),
            'dx': AiDebugSchema.number(),
            'dy': AiDebugSchema.number(),
            'duration_ms': AiDebugSchema.integer(
              min: 1,
              max: gestureMaxMs,
              default_: dragDurationDefault,
            ),
            'steps': AiDebugSchema.integer(min: 1, max: 120, default_: 12),
          },
          required: const ['view_id', 'x', 'y', 'dx', 'dy'],
        ),
      ]),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.drag(
          selector: _optionalSelector(args),
          viewId: args['view_id'] as int?,
          x: (args['x'] as num?)?.toDouble(),
          y: (args['y'] as num?)?.toDouble(),
          dx: (args['dx'] as num).toDouble(),
          dy: (args['dy'] as num).toDouble(),
          duration: Duration(
            milliseconds: (args['duration_ms'] as int?) ?? dragDurationDefault,
          ),
          steps: (args['steps'] as int?) ?? 12,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.pinch',
      title: 'Pinch in the Flutter view',
      description:
          'Dispatch a bounded two-pointer pinch around a unique target center, or explicit logical coordinates when allowed.',
      inputSchema: AiDebugSchema.oneOf([
        AiDebugSchema.object(
          {
            'selector': selectorSchema,
            'scale': AiDebugSchema.number(min: 0.1, max: 10),
            'start_span': AiDebugSchema.number(min: 0.1, default_: 80),
            'duration_ms': AiDebugSchema.integer(
              min: 1,
              max: gestureMaxMs,
              default_: pinchDurationDefault,
            ),
            'steps': AiDebugSchema.integer(min: 1, max: 120, default_: 12),
          },
          required: const ['selector', 'scale'],
        ),
        AiDebugSchema.object(
          {
            'view_id': AiDebugSchema.integer(min: 0),
            'x': AiDebugSchema.number(),
            'y': AiDebugSchema.number(),
            'scale': AiDebugSchema.number(min: 0.1, max: 10),
            'start_span': AiDebugSchema.number(min: 0.1, default_: 80),
            'duration_ms': AiDebugSchema.integer(
              min: 1,
              max: gestureMaxMs,
              default_: pinchDurationDefault,
            ),
            'steps': AiDebugSchema.integer(min: 1, max: 120, default_: 12),
          },
          required: const ['view_id', 'x', 'y', 'scale'],
        ),
      ]),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.pinch(
          selector: _optionalSelector(args),
          viewId: args['view_id'] as int?,
          x: (args['x'] as num?)?.toDouble(),
          y: (args['y'] as num?)?.toDouble(),
          scale: (args['scale'] as num).toDouble(),
          startSpan: (args['start_span'] as num?)?.toDouble() ?? 80,
          duration: Duration(
            milliseconds: (args['duration_ms'] as int?) ?? pinchDurationDefault,
          ),
          steps: (args['steps'] as int?) ?? 12,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.scroll',
      title: 'Scroll a semantics node',
      description:
          'Scroll toward a content direction using an advertised semantics action. The scrollable must be unique.',
      inputSchema: AiDebugSchema.object(
        {
          'selector': selectorSchema,
          'direction': AiDebugSchema.string(
            enum_: const ['down', 'up', 'right', 'left'],
          ),
          'count': AiDebugSchema.integer(
            min: 1,
            max: limits.maxScrolls,
            default_: 1,
          ),
        },
        required: ['direction'],
      ),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.scroll(
          selector: _optionalSelector(args),
          direction: args['direction'] as String,
          count: (args['count'] as int?) ?? 1,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.scroll_until',
      title: 'Scroll until a target appears',
      description:
          'Repeatedly scroll a unique semantics scrollable until a target appears, an extent stops changing, or a bound is reached.',
      inputSchema: AiDebugSchema.object(
        {
          'target': selectorSchema,
          'scrollable': selectorSchema,
          'direction': AiDebugSchema.string(
            enum_: const ['down', 'up', 'right', 'left'],
          ),
          'max_scrolls': AiDebugSchema.integer(
            min: 1,
            max: limits.maxScrolls,
            default_: scrollDefault,
          ),
          'timeout_ms': AiDebugSchema.integer(
            min: 0,
            max: waitMaxMs,
            default_: scrollWaitDefault,
          ),
        },
        required: ['target', 'direction'],
      ),
      annotations: _mutating,
      handler: _tool(
        (args) => automation.scrollUntil(
          target: _selectorNamed(args, 'target'),
          scrollable: _optionalSelectorNamed(args, 'scrollable'),
          direction: args['direction'] as String,
          maxScrolls: (args['max_scrolls'] as int?) ?? scrollDefault,
          timeout: Duration(
            milliseconds: (args['timeout_ms'] as int?) ?? scrollWaitDefault,
          ),
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.wait',
      title: 'Wait for a UI condition',
      description:
          'Wait for matching semantics nodes to appear or disappear. The initial state is checked even with a zero timeout.',
      inputSchema: AiDebugSchema.object(
        {
          'selector': selectorSchema,
          'absent': AiDebugSchema.boolean(default_: false),
          'timeout_ms': AiDebugSchema.integer(
            min: 0,
            max: waitMaxMs,
            default_: waitDefault,
          ),
          'poll_ms': AiDebugSchema.integer(min: 30, max: 5000, default_: 100),
          'stable_ms': AiDebugSchema.integer(
            min: 0,
            max: waitMaxMs,
            default_: 0,
          ),
        },
        required: ['selector'],
      ),
      annotations: _readOnly,
      handler: _tool(
        (args) => automation.wait(
          selector: _selector(args),
          absent: args['absent'] == true,
          timeout: Duration(
            milliseconds: (args['timeout_ms'] as int?) ?? waitDefault,
          ),
          poll: Duration(milliseconds: (args['poll_ms'] as int?) ?? 100),
          stable: Duration(milliseconds: (args['stable_ms'] as int?) ?? 0),
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'ui.run',
      title: 'Run a bounded UI sequence',
      description:
          'Run activate, tap, double_tap, long_press, drag, pinch, scroll, scroll_until, and wait steps in order. Stops at the first failed step.',
      inputSchema: AiDebugSchema.object(
        {
          'steps': AiDebugSchema.array(
            _stepSchema(
              selector: selectorSchema,
              gestureMaxMs: gestureMaxMs,
              doubleTapIntervalMax: doubleTapIntervalMax,
              maxScrolls: limits.maxScrolls,
              waitMaxMs: waitMaxMs,
            ),
            minItems: 1,
            maxItems: limits.maxRunSteps,
          ),
          'timeout_ms': AiDebugSchema.integer(
            min: 0,
            max: waitMaxMs,
            default_: waitMaxMs,
          ),
        },
        required: ['steps'],
      ),
      annotations: _mutating,
      handler: _tool((args) {
        final steps = (args['steps'] as List)
            .map((step) => Map<String, dynamic>.from(step as Map))
            .toList(growable: false);
        return automation.run(
          steps,
          timeout: Duration(
            milliseconds: (args['timeout_ms'] as int?) ?? waitMaxMs,
          ),
        );
      }),
    ),
  );
}

Future<void> disposeAutomationTools() async {
  final automation = _automation;
  _automation = null;
  await automation?.dispose();
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

AiDebugSchema _selectorSchema(int maxStringLength) {
  final properties = <String, AiDebugSchema>{
    'identifier': AiDebugSchema.string(
      minLength: 1,
      maxLength: maxStringLength,
    ),
    'label': AiDebugSchema.string(minLength: 1, maxLength: maxStringLength),
    'text': AiDebugSchema.string(minLength: 1, maxLength: maxStringLength),
    'value': AiDebugSchema.string(minLength: 1, maxLength: maxStringLength),
    'hint': AiDebugSchema.string(minLength: 1, maxLength: maxStringLength),
    'tooltip': AiDebugSchema.string(minLength: 1, maxLength: maxStringLength),
    'action': AiDebugSchema.string(enum_: uiActionNames.keys.toList()),
    'view_id': AiDebugSchema.integer(min: 0),
    'enabled': AiDebugSchema.boolean(),
    'focused': AiDebugSchema.boolean(),
    'text_field': AiDebugSchema.boolean(),
    'nth': AiDebugSchema.integer(min: 0),
    'match': AiDebugSchema.string(
      enum_: const ['exact', 'contains', 'starts_with'],
      default_: 'exact',
    ),
    'case_sensitive': AiDebugSchema.boolean(default_: true),
  };
  const requiredAny = [
    'identifier',
    'label',
    'text',
    'value',
    'hint',
    'tooltip',
    'action',
    'view_id',
    'enabled',
    'focused',
    'text_field',
  ];
  return AiDebugSchema.oneOf([
    AiDebugSchema.object(properties, requiredAny: requiredAny),
    AiDebugSchema.object(
      {'id': AiDebugSchema.integer(min: 0), ...properties},
      required: const ['id', 'view_id'],
    ),
  ]);
}

AiDebugSchema _stepSchema({
  required AiDebugSchema selector,
  required int gestureMaxMs,
  required int doubleTapIntervalMax,
  required int maxScrolls,
  required int waitMaxMs,
}) {
  final duration = AiDebugSchema.integer(min: 1, max: gestureMaxMs);
  final steps = AiDebugSchema.integer(min: 1, max: 120);
  final direction = AiDebugSchema.string(
    enum_: const ['down', 'up', 'right', 'left'],
  );
  final dx = AiDebugSchema.number();
  final dy = AiDebugSchema.number();
  final scale = AiDebugSchema.number(min: 0.1, max: 10);
  final viewId = AiDebugSchema.integer(min: 0);
  final x = AiDebugSchema.number();
  final y = AiDebugSchema.number();
  return AiDebugSchema.oneOf([
    for (final schema in _activateSchemas(selector, op: 'activate')) schema,
    _step('tap', {'selector': selector}, const ['selector']),
    _step(
      'double_tap',
      {
        'selector': selector,
        'interval_ms': AiDebugSchema.integer(
          min: 40,
          max: doubleTapIntervalMax,
        ),
      },
      const ['selector'],
    ),
    _step(
      'long_press',
      {'selector': selector, 'hold_ms': duration},
      const ['selector'],
    ),
    _step(
      'long_press',
      {'view_id': viewId, 'x': x, 'y': y, 'hold_ms': duration},
      const ['view_id', 'x', 'y'],
    ),
    _step(
      'drag',
      {
        'selector': selector,
        'dx': dx,
        'dy': dy,
        'duration_ms': duration,
        'steps': steps,
      },
      const ['selector', 'dx', 'dy'],
    ),
    _step(
      'drag',
      {
        'view_id': viewId,
        'x': x,
        'y': y,
        'dx': dx,
        'dy': dy,
        'duration_ms': duration,
        'steps': steps,
      },
      const ['view_id', 'x', 'y', 'dx', 'dy'],
    ),
    _step(
      'pinch',
      {
        'selector': selector,
        'scale': scale,
        'start_span': AiDebugSchema.number(min: 0.1),
        'duration_ms': duration,
        'steps': steps,
      },
      const ['selector', 'scale'],
    ),
    _step(
      'pinch',
      {
        'view_id': viewId,
        'x': x,
        'y': y,
        'scale': scale,
        'start_span': AiDebugSchema.number(min: 0.1),
        'duration_ms': duration,
        'steps': steps,
      },
      const ['view_id', 'x', 'y', 'scale'],
    ),
    _step(
      'scroll',
      {
        'selector': selector,
        'direction': direction,
        'count': AiDebugSchema.integer(min: 1, max: maxScrolls),
      },
      const ['direction'],
    ),
    _step(
      'scroll_until',
      {
        'target': selector,
        'scrollable': selector,
        'direction': direction,
        'max_scrolls': AiDebugSchema.integer(min: 1, max: maxScrolls),
        'timeout_ms': AiDebugSchema.integer(min: 0, max: waitMaxMs),
      },
      const ['target', 'direction'],
    ),
    _step(
      'wait',
      {
        'selector': selector,
        'absent': AiDebugSchema.boolean(),
        'timeout_ms': AiDebugSchema.integer(min: 0, max: waitMaxMs),
        'poll_ms': AiDebugSchema.integer(min: 30, max: 5000),
        'stable_ms': AiDebugSchema.integer(min: 0, max: waitMaxMs),
      },
      const ['selector'],
    ),
  ]);
}

AiDebugSchema _activateSchema(AiDebugSchema selector) =>
    AiDebugSchema.oneOf(_activateSchemas(selector));

List<AiDebugSchema> _activateSchemas(AiDebugSchema selector, {String? op}) {
  final prefix = <String, AiDebugSchema>{
    if (op != null) 'op': AiDebugSchema.string(enum_: [op]),
    'selector': selector,
  };
  final required = [if (op != null) 'op', 'selector', 'action'];
  return [
    AiDebugSchema.object(
      {
        ...prefix,
        'action': AiDebugSchema.string(enum_: const ['setText']),
        'text': AiDebugSchema.string(maxLength: 65536),
      },
      required: [...required, 'text'],
    ),
    AiDebugSchema.object(
      {
        ...prefix,
        'action': AiDebugSchema.string(enum_: const ['setSelection']),
        'base': AiDebugSchema.integer(min: 0),
        'extent': AiDebugSchema.integer(min: 0),
      },
      required: [...required, 'base', 'extent'],
    ),
    AiDebugSchema.object({
      ...prefix,
      'action': AiDebugSchema.string(
        enum_: uiActionNames.keys
            .where((name) => name != 'setText' && name != 'setSelection')
            .toList(growable: false),
      ),
    }, required: required),
  ];
}

AiDebugSchema _step(
  String op,
  Map<String, AiDebugSchema> properties,
  List<String> required,
) => AiDebugSchema.object(
  {
    'op': AiDebugSchema.string(enum_: [op]),
    ...properties,
  },
  required: ['op', ...required],
);

AiDebugHandler _tool(
  FutureOr<Object?> Function(Map<String, dynamic>) handler,
) => handler;

UiSelector _selector(Map<String, dynamic> args) =>
    _selectorNamed(args, 'selector');

UiSelector _selectorNamed(Map<String, dynamic> args, String name) {
  final value = args[name];
  if (value is! Map) {
    throw UiAutomationError('invalid_selector', '$name must be an object');
  }
  return UiSelector.fromJson(Map<String, dynamic>.from(value));
}

UiSelector? _optionalSelector(Map<String, dynamic> args) =>
    _optionalSelectorNamed(args, 'selector');

UiSelector? _optionalSelectorNamed(Map<String, dynamic> args, String name) {
  if (args[name] == null) return null;
  return _selectorNamed(args, name);
}
