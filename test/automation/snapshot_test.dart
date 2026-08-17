import 'dart:async';
import 'dart:ui' as ui;

import 'package:ai_debug/src/automation/controller.dart';
import 'package:ai_debug/src/automation/gesture_driver.dart';
import 'package:ai_debug/src/automation/models.dart';
import 'package:ai_debug/src/automation/target.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('snapshot uses semantics and redacts text fields', (
    tester,
  ) async {
    final text = TextEditingController(text: 'private value');
    addTearDown(text.dispose);
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                identifier: 'save.button',
                label: 'Save',
                button: true,
                onTap: () {},
                child: const SizedBox(width: 80, height: 40),
              ),
              TextField(controller: text),
            ],
          ),
        ),
      ),
    );
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final future = automation.snapshot();
    await _frames(tester);
    final result = await future;
    final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();

    final save = nodes.singleWhere(
      (node) => node['identifier'] == 'save.button',
    );
    expect(save['label'], 'Save');
    expect((save['actions'] as List).contains('tap'), isTrue);
    final fields = nodes.where((node) => node['text_field'] == true).toList();
    expect(fields, isNotEmpty);
    expect(fields.every((node) => node['value'] == null), isTrue);
    expect(fields.any((node) => node['value_redacted'] == true), isTrue);
  });

  testWidgets('activate rejects ambiguity and dispatches a unique action', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 2; i++)
              Semantics(
                identifier: 'item.$i',
                label: 'Item',
                button: true,
                onTap: () => taps++,
                child: const SizedBox(width: 80, height: 40),
              ),
          ],
        ),
      ),
    );
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final ambiguous = automation.activate(
      const UiSelector(label: 'Item'),
      'tap',
    );
    final ambiguousExpectation = expectLater(
      ambiguous,
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'ambiguous_target',
        ),
      ),
    );
    await _frames(tester);
    await ambiguousExpectation;

    final action = automation.activate(
      const UiSelector(identifier: 'item.1'),
      'tap',
    );
    await _frames(tester);
    final result = await action;
    expect(result['dispatched'], isTrue);
    expect(taps, 1);
  });

  testWidgets('snapshot node id targets an unlabeled semantics node', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Semantics(
          button: true,
          onTap: () => taps++,
          child: const SizedBox(width: 48, height: 48),
        ),
      ),
    );
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final snapshot = automation.snapshot();
    await _frames(tester);
    final nodes = ((await snapshot)['nodes'] as List)
        .cast<Map<String, Object?>>();
    final node = nodes.singleWhere(
      (node) => (node['actions'] as List).contains('tap'),
    );
    expect(node['label'], isNull);
    expect(node['identifier'], isNull);

    final action = automation.activate(
      UiSelector(id: node['id']! as int, viewId: node['view_id']! as int),
      'tap',
    );
    await _frames(tester);
    expect((await action)['dispatched'], isTrue);
    expect(taps, 1);
  });

  testWidgets('detached semantics id does not target its replacement', (
    tester,
  ) async {
    var taps = 0;
    Widget target(int key) => KeyedSubtree(
      key: ValueKey(key),
      child: Semantics(
        button: true,
        onTap: () => taps++,
        child: const SizedBox(width: 48, height: 48),
      ),
    );
    await tester.pumpWidget(_host(target(1)));
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final snapshot = automation.snapshot();
    await _frames(tester);
    final nodes = ((await snapshot)['nodes'] as List)
        .cast<Map<String, Object?>>();
    final node = nodes.singleWhere(
      (node) => (node['actions'] as List).contains('tap'),
    );

    await tester.pumpWidget(_host(target(2)));
    final action = automation.activate(
      UiSelector(id: node['id']! as int, viewId: node['view_id']! as int),
      'tap',
    );
    final expectation = expectLater(
      action,
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'target_not_found',
        ),
      ),
    );
    await _frames(tester);
    await expectation;
    expect(taps, 0);
  });

  testWidgets('zero-time wait checks the initial snapshot', (tester) async {
    await tester.pumpWidget(
      _host(
        Semantics(
          identifier: 'ready',
          label: 'Ready',
          child: const SizedBox(width: 20, height: 20),
        ),
      ),
    );
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final future = automation.wait(
      selector: const UiSelector(identifier: 'ready'),
      timeout: Duration.zero,
    );
    await _frames(tester);
    final result = await future;

    expect(result['ok'], isTrue);
    expect(result['condition'], 'present');
  });

  testWidgets('failed wait throws a typed error', (tester) async {
    await tester.pumpWidget(_host(const SizedBox(width: 20, height: 20)));
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final future = automation.wait(
      selector: const UiSelector(identifier: 'missing'),
      timeout: Duration.zero,
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'wait_timeout',
        ),
      ),
    );
    await _frames(tester);
    await expectation;
  });

  testWidgets('run throws with the failed step and cause', (tester) async {
    await tester.pumpWidget(_host(const SizedBox(width: 20, height: 20)));
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final future = automation.run([
      {
        'op': 'tap',
        'selector': {'identifier': 'missing'},
      },
    ]);
    final expectation = expectLater(
      future,
      throwsA(
        isA<UiAutomationError>()
            .having((error) => error.code, 'code', 'run_step_failed')
            .having(
              (error) => (error.details as Map)['failed_step'],
              'failed step',
              0,
            ),
      ),
    );
    await _frames(tester);
    await expectation;
  });

  testWidgets('run waits for a late gesture then reports its deadline', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const SizedBox()));
    final gestures = _BlockingGestures();
    final automation = UiAutomationController(
      config: const UiAutomationConfig(allowRawCoordinates: true),
      gestures: gestures,
    );
    addTearDown(automation.dispose);

    final run = automation.run([
      {'op': 'drag', 'view_id': 0, 'x': 0.0, 'y': 0.0, 'dx': 1.0, 'dy': 0.0},
    ], timeout: const Duration(milliseconds: 1));
    final expectation = expectLater(
      run,
      throwsA(
        isA<UiAutomationError>()
            .having((error) => error.code, 'code', 'run_timeout')
            .having(
              (error) => (error.details as Map)['failed_step'],
              'failed step',
              0,
            ),
      ),
    );
    await tester.pump();
    expect(gestures.calls, 1);

    final queued = automation.drag(viewId: 0, x: 0, y: 0, dx: 1, dy: 0);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(gestures.calls, 1);

    gestures.release(0);
    await _frames(tester);
    await expectation;
    await tester.pump();
    expect(gestures.calls, 2);

    gestures.release(1);
    await _frames(tester);
    await queued;
  });

  testWidgets('run defaults fit custom gesture limits', (tester) async {
    await tester.pumpWidget(_host(const SizedBox()));
    final gestures = _RecordingGestures();
    final automation = UiAutomationController(
      config: const UiAutomationConfig(
        allowRawCoordinates: true,
        limits: UiAutomationLimits(maxGesture: Duration(milliseconds: 120)),
      ),
      gestures: gestures,
    );
    addTearDown(automation.dispose);

    final run = automation.run([
      {'op': 'drag', 'view_id': 0, 'x': 0.0, 'y': 0.0, 'dx': 1.0, 'dy': 0.0},
    ]);
    await _frames(tester);

    expect((await run)['ok'], isTrue);
    expect(gestures.duration, const Duration(milliseconds: 120));
  });

  testWidgets('long press uses one target and the requested hold', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AiDebugTarget(
          id: 'menu.item',
          child: SizedBox(width: 80, height: 40),
        ),
      ),
    );
    final gestures = _RecordingGestures();
    final automation = UiAutomationController(gestures: gestures);
    addTearDown(automation.dispose);

    final press = automation.longPress(
      selector: const UiSelector(identifier: 'menu.item'),
      hold: const Duration(milliseconds: 550),
    );
    await _frames(tester);

    final result = await press;
    expect(result['gesture'], 'long_press');
    expect(result['hold_ms'], 550);
    expect(gestures.hold, const Duration(milliseconds: 550));
    expect(gestures.tapCalls, 1);

    await expectLater(
      automation.longPress(viewId: 0, x: 1, y: 1),
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'capability_disabled',
        ),
      ),
    );
  });

  testWidgets('AiDebugTarget exposes a stable semantics identifier', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AiDebugTarget(
          id: 'timeline.asset.42',
          child: SizedBox(width: 20, height: 20),
        ),
      ),
    );
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final future = automation.find(
      const UiSelector(identifier: 'timeline.asset.42'),
    );
    await _frames(tester);
    final result = await future;

    expect(result['count'], 1);
  });

  testWidgets('snapshot omits offstage semantics', (tester) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            children: [
              AiDebugTarget(
                id: 'shown',
                child: SizedBox(width: 20, height: 20),
              ),
              Offstage(
                child: AiDebugTarget(
                  id: 'hidden',
                  child: SizedBox(width: 20, height: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final automation = UiAutomationController();
    addTearDown(automation.dispose);

    final future = automation.snapshot();
    await _frames(tester);
    final result = await future;
    final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();

    expect(nodes.any((node) => node['identifier'] == 'shown'), isTrue);
    expect(nodes.any((node) => node['identifier'] == 'hidden'), isFalse);
  });

  testWidgets('snapshot releases its semantics handle', (tester) async {
    await tester.pumpWidget(_host(const SizedBox(width: 20, height: 20)));
    final automation = UiAutomationController();
    addTearDown(automation.dispose);
    final before = SemanticsBinding.instance.debugOutstandingSemanticsHandles;

    final future = automation.snapshot();
    await _frames(tester);
    await future;

    expect(SemanticsBinding.instance.debugOutstandingSemanticsHandles, before);
  });

  testWidgets('dispose prevents later operations', (tester) async {
    await tester.pumpWidget(_host(const SizedBox()));
    final automation = UiAutomationController();
    await automation.dispose();

    final expectation = expectLater(
      automation.snapshot(),
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'disposed',
        ),
      ),
    );
    await _frames(tester);
    await expectation;
  });
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

class _BlockingGestures extends UiGestureDriver {
  final _pending = <Completer<void>>[];
  var calls = 0;

  void release(int index) => _pending[index].complete();

  @override
  Future<void> drag({
    required int viewId,
    required ui.Offset start,
    required ui.Offset delta,
    required Duration duration,
    required int steps,
    required Duration maxDuration,
    required UiCancellation cancellation,
  }) async {
    calls++;
    final pending = Completer<void>();
    _pending.add(pending);
    await pending.future;
  }
}

class _RecordingGestures extends UiGestureDriver {
  Duration? duration;
  Duration? hold;
  var tapCalls = 0;

  @override
  Future<void> tap({
    required int viewId,
    required ui.Offset position,
    required UiCancellation cancellation,
    Duration hold = const Duration(milliseconds: 40),
    Duration maxDuration = const Duration(seconds: 5),
  }) async {
    tapCalls++;
    this.hold = hold;
  }

  @override
  Future<void> drag({
    required int viewId,
    required ui.Offset start,
    required ui.Offset delta,
    required Duration duration,
    required int steps,
    required Duration maxDuration,
    required UiCancellation cancellation,
  }) async {
    this.duration = duration;
  }
}
