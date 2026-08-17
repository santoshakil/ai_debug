import 'dart:convert';

import 'package:ai_debug/src/devtools/ui_inspector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('widget and render snapshots are structured and bounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Text('visible'),
            Offstage(offstage: true, child: Text('hidden')),
          ],
        ),
      ),
    );
    const inspector = UiInspector();

    final widgets = inspector.widgetTree();
    final widgetNodes = (widgets['nodes'] as List).cast<Map<String, Object?>>();
    expect(widgetNodes.map((node) => node['widgetType']), contains('Text'));
    expect(
      widgetNodes.any((node) => node['onstageByOffstageAncestors'] == false),
      isTrue,
    );
    expect(widgets['coordinateSpace'], 'global logical pixels');
    expect(widgets['limits'], contains('state'));

    final bounded = inspector.widgetTree(maxNodes: 2);
    expect(bounded['nodeCount'], 2);
    expect(bounded['truncatedByNodeLimit'], isTrue);

    final render = inspector.renderTree();
    expect(render['rootCount'], greaterThan(0));
    expect(render['nodeCount'], greaterThan(0));
    expect(render['nodes'], isNotEmpty);
    expect(render['limits'], contains('layers'));
    final layers = inspector.layerTree();
    expect(layers['rootCount'], greaterThan(0));
    expect(layers['nodeCount'], greaterThan(0));
    expect(layers['nodes'], isNotEmpty);
    expect(layers['limits'], contains('mode'));
    expect(() => jsonEncode(widgets), returnsNormally);
    expect(() => jsonEncode(render), returnsNormally);
    expect(() => jsonEncode(layers), returnsNormally);
  });

  testWidgets('semantics snapshot releases its handle', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Semantics(
          label: 'Save',
          button: true,
          onTap: () {},
          child: const SizedBox(width: 80, height: 40),
        ),
      ),
    );
    const inspector = UiInspector();
    final before = SemanticsBinding.instance.debugOutstandingSemanticsHandles;

    final pending = inspector.semanticsTree();
    await tester.pump();
    final result = await pending;
    final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();

    expect(nodes.any((node) => node['label'] == 'Save'), isTrue);
    expect(
      nodes.any((node) => (node['actions'] as List).contains('tap')),
      isTrue,
    );
    expect(result['limits'], contains('platform'));
    expect(result['coordinateSpaces'], contains('logicalRect'));
    expect(() => jsonEncode(result), returnsNormally);
    expect(SemanticsBinding.instance.debugOutstandingSemanticsHandles, before);
  });

  testWidgets('semantics snapshot redacts text field values', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Semantics(
          textField: true,
          value: 'private text',
          child: const SizedBox(width: 80, height: 40),
        ),
      ),
    );
    const inspector = UiInspector();

    final pending = inspector.semanticsTree();
    await tester.pump();
    final result = await pending;
    final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();
    final field = nodes.firstWhere(
      (node) => (node['flags'] as List).contains('isTextField'),
    );

    expect(field, isNot(contains('value')));
    expect(field['valueRedacted'], isTrue);
    expect(jsonEncode(result), isNot(contains('private text')));
  });

  testWidgets('tree limits are validated', (tester) async {
    await tester.pumpWidget(const SizedBox());
    const inspector = UiInspector();

    expect(() => inspector.widgetTree(maxNodes: 0), throwsRangeError);
    expect(() => inspector.renderTree(maxDepth: 201), throwsRangeError);
    expect(() => inspector.layerTree(maxNodes: 0), throwsRangeError);
    await expectLater(
      inspector.semanticsTree(settleTimeout: Duration.zero),
      throwsArgumentError,
    );
  });
}
