import 'dart:typed_data';

import 'package:ai_debug/ai_debug.dart';
import 'package:ai_debug/src/registry.dart'
    show AiDebugSchemaError, CommandRegistry, ToolEntry;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('map schemas accept arbitrary string keys', () async {
    final registry = CommandRegistry();
    registry.add(
      ToolEntry(
        name: 'map',
        description: 'map',
        inputSchema: AiDebugSchema.object({'value': AiDebugSchema.map()}),
        handler: (args) => args,
      ),
    );

    final result = await registry.dispatch('map', {
      'value': {'nested': true},
    });
    expect(result.json, {
      'value': {'nested': true},
    });
  });

  test('tools are sorted and duplicate registration is explicit', () {
    final registry = CommandRegistry();
    registry.register(_tool('z'));
    registry.register(_tool('a'));

    expect(registry.all.map((tool) => tool.name), ['a', 'z']);
    expect(() => registry.register(_tool('a')), throwsStateError);
  });

  test('schemas are copied at registration', () {
    final schema = AiDebugSchema.object({'name': AiDebugSchema.string()});
    final registry = CommandRegistry()..register(_tool('copy', schema: schema));
    final json = registry.get('copy')!.inputSchema.asJson;
    (json['properties'] as Map<String, dynamic>).clear();

    expect(
      (registry.get('copy')!.inputSchema.asJson['properties'] as Map),
      contains('name'),
    );
  });

  test('input schema rejects missing and extra values', () async {
    final registry = CommandRegistry()
      ..register(
        _tool(
          'strict',
          schema: AiDebugSchema.object(
            {'count': AiDebugSchema.integer(min: 1, max: 3)},
            required: ['count'],
          ),
        ),
      );

    await expectLater(
      registry.dispatch('strict', const {}),
      throwsA(isA<AiDebugSchemaError>()),
    );
    await expectLater(
      registry.dispatch('strict', const {'count': 2, 'extra': true}),
      throwsA(isA<AiDebugSchemaError>()),
    );
    expect((await registry.dispatch('strict', const {'count': 2})).json, {
      'ok': true,
    });
  });

  test('schemas reject long strings and non-finite numbers', () async {
    final registry = CommandRegistry()
      ..register(
        _tool(
          'bounded',
          schema: AiDebugSchema.object(
            {
              'name': AiDebugSchema.string(minLength: 1, maxLength: 3),
              'value': AiDebugSchema.number(),
            },
            required: ['name', 'value'],
          ),
        ),
      );

    await expectLater(
      registry.dispatch('bounded', const {'name': 'long', 'value': 1}),
      throwsA(isA<AiDebugSchemaError>()),
    );
    await expectLater(
      registry.dispatch('bounded', const {'name': 'ok', 'value': double.nan}),
      throwsA(isA<AiDebugSchemaError>()),
    );
  });

  test('output schema is checked for JSON results', () async {
    final registry = CommandRegistry()
      ..register(
        ToolEntry(
          name: 'bad_output',
          description: 'test',
          inputSchema: AiDebugSchema.empty(),
          outputSchema: AiDebugSchema.object(
            {'ok': AiDebugSchema.boolean()},
            required: ['ok'],
          ),
          handler: (_) => {'ok': 'yes'},
        ),
      );

    await expectLater(
      registry.dispatch('bad_output', const {}),
      throwsA(isA<AiDebugSchemaError>()),
    );
  });

  test('binary results bypass JSON output validation', () async {
    final source = Uint8List.fromList([1]);
    final registry = CommandRegistry()
      ..register(
        ToolEntry(
          name: 'image',
          description: 'test',
          inputSchema: AiDebugSchema.empty(),
          outputSchema: AiDebugSchema.empty(),
          handler: (_) => AiDebugResult.binary(source, mime: 'IMAGE/PNG'),
        ),
      );

    final result = await registry.dispatch('image', const {});
    source[0] = 2;
    expect(result.binary, [1]);
    expect(result.binaryMime, 'image/png');
    expect(
      () => AiDebugResult.binary(Uint8List(1), mime: 'bad\r\ntype'),
      throwsArgumentError,
    );
  });

  test('tool names use the MCP safe character set', () {
    final registry = CommandRegistry();
    expect(() => registry.register(_tool('ui.tap')), returnsNormally);
    expect(() => registry.register(_tool('bad name')), throwsArgumentError);
    expect(() => registry.register(_tool('')), throwsArgumentError);
  });

  test('tool definitions are bounded and JSON-safe', () {
    final registry = CommandRegistry();

    expect(
      () => registry.register(
        ToolEntry(
          name: 'large_description',
          description: 'x' * 4097,
          inputSchema: AiDebugSchema.empty(),
          handler: (_) => null,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => registry.register(
        ToolEntry(
          name: 'to_json_annotation',
          description: 'test',
          inputSchema: AiDebugSchema.empty(),
          annotations: {'bad': _MutableJson()},
          handler: (_) => null,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => registry.register(
        ToolEntry(
          name: 'bad_annotation',
          description: 'test',
          inputSchema: AiDebugSchema.empty(),
          annotations: {'bad': Object()},
          handler: (_) => null,
        ),
      ),
      throwsArgumentError,
    );
    final cycle = <String, Object?>{};
    cycle['cycle'] = cycle;
    expect(
      () => registry.register(
        ToolEntry(
          name: 'cyclic_annotation',
          description: 'test',
          inputSchema: AiDebugSchema.empty(),
          annotations: cycle,
          handler: (_) => null,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('annotations are copied deeply at registration', () {
    final nested = <String, Object?>{'value': true};
    final annotations = <String, Object?>{'nested': nested};
    final registry = CommandRegistry()
      ..register(
        ToolEntry(
          name: 'annotations',
          description: 'test',
          inputSchema: AiDebugSchema.empty(),
          annotations: annotations,
          handler: (_) => null,
        ),
      );

    nested['value'] = false;
    final saved = registry.get('annotations')!.annotations!;
    expect(saved, {
      'nested': {'value': true},
    });
    expect(
      () => (saved['nested']! as Map<String, Object?>)['value'] = false,
      throwsUnsupportedError,
    );
  });

  test('known MCP annotations use their protocol types', () {
    final registry = CommandRegistry();

    for (final annotations in [
      const <String, Object?>{'readOnlyHint': 'yes'},
      const <String, Object?>{'destructiveHint': 1},
      const <String, Object?>{'idempotentHint': null, 'openWorldHint': []},
      const <String, Object?>{'title': ''},
    ]) {
      expect(
        () => registry.register(
          ToolEntry(
            name: 'bad_annotation_${registry.all.length}',
            description: 'test',
            inputSchema: AiDebugSchema.empty(),
            annotations: annotations,
            handler: (_) => null,
          ),
        ),
        throwsArgumentError,
      );
    }
  });

  test('object schema can require any one match property', () {
    final schema = AiDebugSchema.object(
      {
        'label': AiDebugSchema.string(),
        'value': AiDebugSchema.string(),
        'visible': AiDebugSchema.boolean(),
      },
      requiredAny: const ['label', 'value'],
    );

    expect(() => schema.validate({'label': 'save'}), returnsNormally);
    expect(() => schema.validate({'value': 'one'}), returnsNormally);
    expect(
      () => schema.validate({'visible': true}),
      throwsA(isA<AiDebugSchemaError>()),
    );
  });

  test('schema definitions reject impossible ranges and defaults', () {
    final registry = CommandRegistry();

    for (final schema in [
      AiDebugSchema.integer(min: 2, max: 1),
      AiDebugSchema.number(min: double.nan),
      AiDebugSchema.array(AiDebugSchema.string(), minItems: 2, maxItems: 1),
      AiDebugSchema.string(minLength: 2, default_: 'x'),
      AiDebugSchema.string(enum_: const []),
      AiDebugSchema.object(const {}, required: const ['missing']),
    ]) {
      expect(
        () => registry.register(
          _tool('bad_${registry.all.length}', schema: schema),
        ),
        throwsArgumentError,
      );
    }
  });

  test('oneOf accepts exactly one matching schema', () {
    final schema = AiDebugSchema.oneOf([
      AiDebugSchema.object(
        {
          'op': AiDebugSchema.string(enum_: const ['tap']),
          'target': AiDebugSchema.string(),
        },
        required: const ['op', 'target'],
      ),
      AiDebugSchema.object(
        {
          'op': AiDebugSchema.string(enum_: const ['wait']),
          'delay': AiDebugSchema.integer(),
        },
        required: const ['op', 'delay'],
      ),
    ]);

    expect(
      () => schema.validate({'op': 'tap', 'target': 'one'}),
      returnsNormally,
    );
    expect(
      () => schema.validate({'op': 'tap'}),
      throwsA(isA<AiDebugSchemaError>()),
    );
    expect(
      () => schema.validate({'op': 'other'}),
      throwsA(isA<AiDebugSchemaError>()),
    );
    expect(schema.asJson['type'], 'object');
  });

  test('tool input schemas always advertise an object root', () {
    final registry = CommandRegistry();

    expect(
      () => registry.register(_tool('any', schema: AiDebugSchema.any())),
      throwsArgumentError,
    );
    expect(
      () => registry.register(_tool('string', schema: AiDebugSchema.string())),
      throwsArgumentError,
    );
  });

  test('tool output schemas always advertise an object root', () {
    final registry = CommandRegistry();

    for (final schema in [AiDebugSchema.any(), AiDebugSchema.string()]) {
      expect(
        () => registry.register(
          ToolEntry(
            name: 'bad_output_${registry.all.length}',
            description: 'test',
            inputSchema: AiDebugSchema.empty(),
            outputSchema: schema,
            handler: (_) => null,
          ),
        ),
        throwsArgumentError,
      );
    }
  });
}

ToolEntry _tool(String name, {AiDebugSchema? schema}) => ToolEntry(
  name: name,
  description: 'test',
  inputSchema: schema ?? AiDebugSchema.empty(),
  handler: (_) => {'ok': true},
);

class _MutableJson {
  var value = true;

  Map<String, Object?> toJson() => {'value': value};
}
