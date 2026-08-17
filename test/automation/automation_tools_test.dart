import 'package:ai_debug/src/automation/models.dart';
import 'package:ai_debug/src/builtins/automation_tools.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registers multi-touch gestures', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);

    registerAutomationTools(registry);

    expect(registry.get('ui.double_tap'), isNotNull);
    expect(registry.get('ui.long_press'), isNotNull);
    expect(registry.get('ui.pinch'), isNotNull);
  });

  test('tool errors escape the registry handler', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);
    registerAutomationTools(
      registry,
      config: const UiAutomationConfig(enabled: false),
    );

    await expectLater(
      registry.dispatch('ui.snapshot', const {}),
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'capability_disabled',
        ),
      ),
    );
  });

  test('selector strings are bounded before a snapshot', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);
    registerAutomationTools(
      registry,
      config: const UiAutomationConfig(
        limits: UiAutomationLimits(maxStringLength: 5),
      ),
    );

    await expectLater(
      registry.dispatch('ui.find', const {
        'selector': {'text': 'too long'},
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
  });

  test('selector schemas describe and validate every field', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);
    registerAutomationTools(registry);

    final schema = registry.get('ui.find')!.inputSchema.asJson;
    final selector =
        (schema['properties'] as Map<String, dynamic>)['selector']
            as Map<String, dynamic>;
    final branches = (selector['oneOf'] as List).cast<Map<String, dynamic>>();
    final textBranch = branches.singleWhere(
      (branch) => !(branch['properties'] as Map).containsKey('id'),
    );
    final idBranch = branches.singleWhere(
      (branch) => (branch['properties'] as Map).containsKey('id'),
    );
    expect(textBranch['additionalProperties'], isFalse);
    expect(
      (textBranch['properties'] as Map),
      containsPair('identifier', isMap),
    );
    expect((textBranch['properties'] as Map), containsPair('match', isMap));
    expect(idBranch['required'], containsAll(['id', 'view_id']));

    await expectLater(
      registry.dispatch('ui.find', const {
        'selector': {'identifier': 'item', 'unknown': true},
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
    await expectLater(
      registry.dispatch('ui.find', const {
        'selector': {'identifier': 1},
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
    await expectLater(
      registry.dispatch('ui.find', const {
        'selector': {'text': ''},
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
    await expectLater(
      registry.dispatch('ui.find', const {
        'selector': {'id': 1},
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
    for (final selector in [
      const <String, Object?>{},
      const <String, Object?>{'visible': true},
      const <String, Object?>{'match': 'contains'},
    ]) {
      await expectLater(
        registry.dispatch('ui.find', {'selector': selector}),
        throwsA(isA<AiDebugSchemaError>()),
      );
    }
  });

  test('run step schema is strict and typed', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);
    registerAutomationTools(registry);

    final schema = registry.get('ui.run')!.inputSchema.asJson;
    final steps =
        (schema['properties'] as Map<String, dynamic>)['steps']
            as Map<String, dynamic>;
    final item = steps['items'] as Map<String, dynamic>;
    final branches = item['oneOf'] as List<dynamic>;
    expect(branches, hasLength(14));
    for (final branch in branches.cast<Map<String, dynamic>>()) {
      expect(branch['additionalProperties'], isFalse);
      expect(branch['required'], contains('op'));
    }

    await expectLater(
      registry.dispatch('ui.run', const {
        'steps': [
          {
            'op': 'tap',
            'selector': {'identifier': 'item'},
            'extra': true,
          },
        ],
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
    for (final step in [
      const {'op': 'tap'},
      const {'op': 'drag', 'dx': 1, 'dy': 1},
      const {'op': 'pinch', 'scale': 2},
      const {'op': 'long_press'},
      const {'op': 'scroll'},
      const {'op': 'scroll_until', 'direction': 'down'},
      const {'op': 'wait'},
      const {
        'op': 'activate',
        'selector': {'identifier': 'field'},
        'action': 'setText',
      },
    ]) {
      await expectLater(
        registry.dispatch('ui.run', {
          'steps': [step],
        }),
        throwsA(isA<AiDebugSchemaError>()),
      );
    }
    await expectLater(
      registry.dispatch('ui.run', const {
        'steps': [
          {'op': 'drag', 'dx': 'right', 'dy': 1},
        ],
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
  });

  test('gesture tools require one complete target form', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);
    registerAutomationTools(registry);

    for (final call in <(String, Map<String, Object?>)>[
      ('ui.drag', const {'dx': 1, 'dy': 1}),
      ('ui.drag', const {'view_id': 1, 'x': 1, 'dx': 1, 'dy': 1}),
      (
        'ui.drag',
        const {
          'selector': {'identifier': 'item'},
          'view_id': 1,
          'x': 1,
          'y': 1,
          'dx': 1,
          'dy': 1,
        },
      ),
      ('ui.pinch', const {'scale': 2}),
      ('ui.pinch', const {'view_id': 1, 'x': 1, 'scale': 2}),
      (
        'ui.pinch',
        const {
          'selector': {'identifier': 'item'},
          'view_id': 1,
          'x': 1,
          'y': 1,
          'scale': 2,
        },
      ),
      ('ui.long_press', const {}),
      ('ui.long_press', const {'view_id': 1, 'x': 1}),
      (
        'ui.long_press',
        const {
          'selector': {'identifier': 'item'},
          'view_id': 1,
          'x': 1,
          'y': 1,
        },
      ),
    ]) {
      await expectLater(
        registry.dispatch(call.$1, call.$2),
        throwsA(isA<AiDebugSchemaError>()),
      );
    }
  });

  test('activate text is bounded by its schema', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    addTearDown(disposeAutomationTools);
    registerAutomationTools(registry);

    await expectLater(
      registry.dispatch('ui.activate', {
        'selector': const {'identifier': 'field'},
        'action': 'setText',
        'text': 'x' * 65537,
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
    await expectLater(
      registry.dispatch('ui.activate', const {
        'selector': {'identifier': 'field'},
        'action': 'setText',
      }),
      throwsA(isA<AiDebugSchemaError>()),
    );
  });
}
