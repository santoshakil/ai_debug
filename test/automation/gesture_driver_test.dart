import 'dart:ui';

import 'package:ai_debug/src/automation/gesture_driver.dart';
import 'package:ai_debug/src/automation/models.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tap sends one timestamped sequence to the requested view', () async {
    final events = <PointerEvent>[];
    final driver = UiGestureDriver(
      dispatch: events.add,
      viewSize: (_) => const Size(200, 100),
    );

    await driver.tap(
      viewId: 7,
      position: const Offset(20, 30),
      hold: const Duration(milliseconds: 1),
      cancellation: UiCancellation(),
    );

    expect(events, hasLength(2));
    expect(events.first, isA<PointerDownEvent>());
    expect(events.last, isA<PointerUpEvent>());
    expect(events.map((event) => event.viewId), everyElement(7));
    expect(events.last.timeStamp, greaterThan(events.first.timeStamp));
    expect(driver.activePointerCount, 0);
  });

  test('drag sends increasing timestamps and exact deltas', () async {
    final events = <PointerEvent>[];
    final driver = UiGestureDriver(
      dispatch: events.add,
      viewSize: (_) => const Size(200, 100),
    );

    await driver.drag(
      viewId: 3,
      start: const Offset(20, 20),
      delta: const Offset(60, 40),
      duration: const Duration(milliseconds: 4),
      steps: 4,
      maxDuration: const Duration(seconds: 1),
      cancellation: UiCancellation(),
    );

    expect(events, hasLength(6));
    expect(events.first, isA<PointerDownEvent>());
    expect(events.last, isA<PointerUpEvent>());
    expect(events.last.position, const Offset(80, 60));
    for (var i = 1; i < events.length; i++) {
      expect(events[i].timeStamp, greaterThan(events[i - 1].timeStamp));
    }
    final moved = events.whereType<PointerMoveEvent>();
    expect(
      moved.fold<Offset>(Offset.zero, (sum, event) => sum + event.delta),
      const Offset(60, 40),
    );
  });

  test(
    'drag holds keep the pointer down before moving and before lifting',
    () async {
      final events = <PointerEvent>[];
      final stamps = <Duration>[];
      final driver = UiGestureDriver(
        dispatch: (event) {
          events.add(event);
          stamps.add(event.timeStamp);
        },
        viewSize: (_) => const Size(200, 100),
      );
      final watch = Stopwatch()..start();

      await driver.drag(
        viewId: 3,
        start: const Offset(20, 20),
        delta: const Offset(60, 0),
        duration: const Duration(milliseconds: 4),
        steps: 2,
        maxDuration: const Duration(seconds: 1),
        cancellation: UiCancellation(),
        holdStart: const Duration(milliseconds: 60),
        holdEnd: const Duration(milliseconds: 60),
      );
      watch.stop();

      expect(events.first, isA<PointerDownEvent>());
      expect(events.last, isA<PointerUpEvent>());
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 120)),
      );
      expect(
        stamps[1] - stamps[0],
        greaterThanOrEqualTo(const Duration(milliseconds: 60)),
      );
      expect(
        stamps[stamps.length - 1] - stamps[stamps.length - 2],
        greaterThanOrEqualTo(const Duration(milliseconds: 60)),
      );
    },
  );

  test('double tap sends two separate tap sequences', () async {
    final events = <PointerEvent>[];
    final driver = UiGestureDriver(
      dispatch: events.add,
      viewSize: (_) => const Size(200, 100),
    );

    await driver.doubleTap(
      viewId: 5,
      position: const Offset(80, 40),
      hold: const Duration(milliseconds: 1),
      interval: const Duration(milliseconds: 40),
      maxDuration: const Duration(seconds: 1),
      cancellation: UiCancellation(),
    );

    expect(events, hasLength(4));
    expect(events[0], isA<PointerDownEvent>());
    expect(events[1], isA<PointerUpEvent>());
    expect(events[2], isA<PointerDownEvent>());
    expect(events[3], isA<PointerUpEvent>());
    expect(events[0].pointer, events[1].pointer);
    expect(events[2].pointer, events[3].pointer);
    expect(events[0].pointer, isNot(events[2].pointer));
    for (var i = 1; i < events.length; i++) {
      expect(events[i].timeStamp, greaterThan(events[i - 1].timeStamp));
    }
    expect(driver.activePointerCount, 0);
  });

  test('pinch moves two pointers symmetrically and clears state', () async {
    final events = <PointerEvent>[];
    final driver = UiGestureDriver(
      dispatch: events.add,
      viewSize: (_) => const Size(200, 100),
    );

    await driver.pinch(
      viewId: 2,
      center: const Offset(100, 50),
      startSpan: 80,
      scale: 1.5,
      duration: const Duration(milliseconds: 2),
      steps: 2,
      maxDuration: const Duration(seconds: 1),
      cancellation: UiCancellation(),
    );

    expect(events, hasLength(8));
    expect(events.take(2), everyElement(isA<PointerDownEvent>()));
    expect(events.skip(2).take(4), everyElement(isA<PointerMoveEvent>()));
    expect(events.skip(6), everyElement(isA<PointerUpEvent>()));
    expect(events[6].position, const Offset(160, 50));
    expect(events[7].position, const Offset(40, 50));
    for (var i = 1; i < events.length; i++) {
      expect(events[i].timeStamp, greaterThan(events[i - 1].timeStamp));
    }
    expect(driver.activePointerCount, 0);
  });

  test('cancelled pinch cancels both active pointers', () async {
    final events = <PointerEvent>[];
    final cancellation = UiCancellation();
    final driver = UiGestureDriver(
      dispatch: (event) {
        events.add(event);
        if (event is PointerMoveEvent) cancellation.cancel();
      },
      viewSize: (_) => const Size(200, 100),
    );

    await expectLater(
      driver.pinch(
        viewId: 2,
        center: const Offset(100, 50),
        startSpan: 80,
        scale: 1.5,
        duration: const Duration(milliseconds: 2),
        steps: 2,
        maxDuration: const Duration(seconds: 1),
        cancellation: cancellation,
      ),
      throwsA(isA<UiAutomationError>()),
    );

    expect(events.whereType<PointerCancelEvent>(), hasLength(2));
    expect(driver.activePointerCount, 0);
  });

  test('cancelled gesture sends PointerCancelEvent and clears state', () async {
    final events = <PointerEvent>[];
    final cancellation = UiCancellation();
    final driver = UiGestureDriver(
      dispatch: (event) {
        events.add(event);
        if (event is PointerDownEvent) cancellation.cancel();
      },
      viewSize: (_) => const Size(200, 100),
    );

    await expectLater(
      driver.tap(
        viewId: 1,
        position: const Offset(10, 10),
        cancellation: cancellation,
      ),
      throwsA(isA<UiAutomationError>()),
    );

    expect(events.first, isA<PointerDownEvent>());
    expect(events.last, isA<PointerCancelEvent>());
    expect(driver.activePointerCount, 0);
  });

  test('rejects unknown views and out-of-bounds points', () async {
    final driver = UiGestureDriver(
      dispatch: (_) {},
      viewSize: (viewId) => viewId == 1 ? const Size(100, 100) : null,
    );

    await expectLater(
      driver.tap(
        viewId: 2,
        position: const Offset(1, 1),
        cancellation: UiCancellation(),
      ),
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'view_not_found',
        ),
      ),
    );
    await expectLater(
      driver.tap(
        viewId: 1,
        position: const Offset(100, 1),
        cancellation: UiCancellation(),
      ),
      throwsA(
        isA<UiAutomationError>().having(
          (error) => error.code,
          'code',
          'point_out_of_bounds',
        ),
      ),
    );
  });
}
