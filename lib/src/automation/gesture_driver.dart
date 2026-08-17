import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'models.dart';

typedef UiPointerDispatcher = void Function(PointerEvent event);
typedef UiViewSizeLookup = ui.Size? Function(int viewId);

class UiCancellation {
  final _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelledSignal.isCompleted;

  void cancel() {
    if (!isCancelled) _cancelledSignal.complete();
  }

  void check() {
    if (isCancelled) {
      throw const UiAutomationError('cancelled', 'UI automation was cancelled');
    }
  }

  Future<void> delay(Duration duration) async {
    check();
    if (duration <= Duration.zero) return;
    final cancelled = await Future.any<bool>([
      Future<void>.delayed(duration).then((_) => false),
      _cancelledSignal.future.then((_) => true),
    ]);
    if (cancelled) check();
  }
}

class UiGestureDriver {
  UiGestureDriver({UiPointerDispatcher? dispatch, UiViewSizeLookup? viewSize})
    : _dispatch = dispatch ?? GestureBinding.instance.handlePointerEvent,
      _viewSize = viewSize ?? _bindingViewSize;

  final UiPointerDispatcher _dispatch;
  final UiViewSizeLookup _viewSize;
  final _clock = Stopwatch()..start();
  final _active = <int, ({int viewId, ui.Offset position})>{};
  var _nextPointer = 9000;
  var _lastStamp = Duration.zero;
  var _disposed = false;

  int get activePointerCount => _active.length;

  Future<void> tap({
    required int viewId,
    required ui.Offset position,
    required UiCancellation cancellation,
    Duration hold = const Duration(milliseconds: 40),
    Duration maxDuration = const Duration(seconds: 5),
  }) async {
    _checkReady();
    _validatePoint(viewId, position, 'position');
    if (hold < Duration.zero || hold > maxDuration) {
      throw UiAutomationError(
        'invalid_argument',
        'hold must be between 0 and ${maxDuration.inMilliseconds} ms',
      );
    }
    final pointer = _allocatePointer();
    _active[pointer] = (viewId: viewId, position: position);
    try {
      cancellation.check();
      _dispatch(
        PointerDownEvent(
          viewId: viewId,
          timeStamp: _stamp(),
          pointer: pointer,
          kind: ui.PointerDeviceKind.touch,
          position: position,
        ),
      );
      await cancellation.delay(hold);
      _dispatch(
        PointerUpEvent(
          viewId: viewId,
          timeStamp: _stamp(),
          pointer: pointer,
          kind: ui.PointerDeviceKind.touch,
          position: position,
        ),
      );
      _active.remove(pointer);
    } finally {
      _cancel(pointer);
    }
  }

  Future<void> doubleTap({
    required int viewId,
    required ui.Offset position,
    required UiCancellation cancellation,
    Duration hold = const Duration(milliseconds: 40),
    Duration interval = const Duration(milliseconds: 80),
    required Duration maxDuration,
  }) async {
    _checkReady();
    _validatePoint(viewId, position, 'position');
    if (interval < const Duration(milliseconds: 40) ||
        interval > const Duration(milliseconds: 250)) {
      throw const UiAutomationError(
        'invalid_argument',
        'interval must be between 40 and 250 ms',
      );
    }
    if (hold + hold + interval > maxDuration) {
      throw UiAutomationError(
        'invalid_argument',
        'double tap exceeds the ${maxDuration.inMilliseconds} ms gesture limit',
      );
    }
    await tap(
      viewId: viewId,
      position: position,
      cancellation: cancellation,
      hold: hold,
      maxDuration: maxDuration,
    );
    await cancellation.delay(interval);
    await tap(
      viewId: viewId,
      position: position,
      cancellation: cancellation,
      hold: hold,
      maxDuration: maxDuration,
    );
  }

  Future<void> drag({
    required int viewId,
    required ui.Offset start,
    required ui.Offset delta,
    required Duration duration,
    required int steps,
    required Duration maxDuration,
    required UiCancellation cancellation,
  }) async {
    _checkReady();
    _validatePoint(viewId, start, 'start');
    if (!delta.dx.isFinite || !delta.dy.isFinite) {
      throw const UiAutomationError(
        'invalid_argument',
        'drag delta must be finite',
      );
    }
    final end = start + delta;
    _validatePoint(viewId, end, 'end');
    _validateGesture(duration, steps, maxDuration);

    final pointer = _allocatePointer();
    var position = start;
    _active[pointer] = (viewId: viewId, position: position);
    try {
      cancellation.check();
      _dispatch(
        PointerDownEvent(
          viewId: viewId,
          timeStamp: _stamp(),
          pointer: pointer,
          kind: ui.PointerDeviceKind.touch,
          position: start,
        ),
      );
      final pause = _stepDuration(duration, steps);
      for (var step = 1; step <= steps; step++) {
        await cancellation.delay(pause);
        final next = start + delta * (step / steps);
        _dispatch(
          PointerMoveEvent(
            viewId: viewId,
            timeStamp: _stamp(),
            pointer: pointer,
            kind: ui.PointerDeviceKind.touch,
            position: next,
            delta: next - position,
          ),
        );
        position = next;
        _active[pointer] = (viewId: viewId, position: position);
        cancellation.check();
      }
      _dispatch(
        PointerUpEvent(
          viewId: viewId,
          timeStamp: _stamp(),
          pointer: pointer,
          kind: ui.PointerDeviceKind.touch,
          position: position,
        ),
      );
      _active.remove(pointer);
    } finally {
      _cancel(pointer);
    }
  }

  Future<void> pinch({
    required int viewId,
    required ui.Offset center,
    required double startSpan,
    required double scale,
    required Duration duration,
    required int steps,
    required Duration maxDuration,
    required UiCancellation cancellation,
  }) async {
    _checkReady();
    if (!startSpan.isFinite || startSpan <= 0) {
      throw const UiAutomationError(
        'invalid_argument',
        'start span must be a positive finite number',
      );
    }
    if (!scale.isFinite || scale < 0.1 || scale > 10) {
      throw const UiAutomationError(
        'invalid_argument',
        'scale must be between 0.1 and 10',
      );
    }
    _validateGesture(duration, steps, maxDuration);
    final startHalf = startSpan / 2;
    final endHalf = startHalf * scale;
    final startA = center - ui.Offset(startHalf, 0);
    final startB = center + ui.Offset(startHalf, 0);
    final endA = center - ui.Offset(endHalf, 0);
    final endB = center + ui.Offset(endHalf, 0);
    _validatePoint(viewId, startA, 'first start');
    _validatePoint(viewId, startB, 'second start');
    _validatePoint(viewId, endA, 'first end');
    _validatePoint(viewId, endB, 'second end');

    final first = _allocatePointer();
    final second = _allocatePointer();
    var positionA = startA;
    var positionB = startB;
    try {
      cancellation.check();
      _active[first] = (viewId: viewId, position: positionA);
      _dispatch(
        PointerDownEvent(
          viewId: viewId,
          timeStamp: _stamp(),
          pointer: first,
          kind: ui.PointerDeviceKind.touch,
          position: positionA,
        ),
      );
      cancellation.check();
      _active[second] = (viewId: viewId, position: positionB);
      _dispatch(
        PointerDownEvent(
          viewId: viewId,
          timeStamp: _stamp(),
          pointer: second,
          kind: ui.PointerDeviceKind.touch,
          position: positionB,
        ),
      );
      final pause = _stepDuration(duration, steps);
      for (var step = 1; step <= steps; step++) {
        await cancellation.delay(pause);
        final t = step / steps;
        final nextA = ui.Offset.lerp(startA, endA, t)!;
        final nextB = ui.Offset.lerp(startB, endB, t)!;
        _move(first, viewId, positionA, nextA);
        positionA = nextA;
        _move(second, viewId, positionB, nextB);
        positionB = nextB;
        cancellation.check();
      }
      _up(second, viewId, positionB);
      _up(first, viewId, positionA);
    } finally {
      _cancel(second);
      _cancel(first);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pointer in _active.keys.toList()) {
      _cancel(pointer);
    }
  }

  int _allocatePointer() {
    while (_active.containsKey(_nextPointer)) {
      _nextPointer++;
    }
    return _nextPointer++;
  }

  Duration _stamp() {
    var next = _clock.elapsed;
    if (next <= _lastStamp) {
      next = _lastStamp + const Duration(microseconds: 1);
    }
    _lastStamp = next;
    return next;
  }

  void _cancel(int pointer) {
    final active = _active.remove(pointer);
    if (active == null) return;
    try {
      _dispatch(
        PointerCancelEvent(
          viewId: active.viewId,
          timeStamp: _stamp(),
          pointer: pointer,
          kind: ui.PointerDeviceKind.touch,
          position: active.position,
        ),
      );
    } catch (_) {}
  }

  void _move(int pointer, int viewId, ui.Offset previous, ui.Offset next) {
    _dispatch(
      PointerMoveEvent(
        viewId: viewId,
        timeStamp: _stamp(),
        pointer: pointer,
        kind: ui.PointerDeviceKind.touch,
        position: next,
        delta: next - previous,
      ),
    );
    _active[pointer] = (viewId: viewId, position: next);
  }

  void _up(int pointer, int viewId, ui.Offset position) {
    _dispatch(
      PointerUpEvent(
        viewId: viewId,
        timeStamp: _stamp(),
        pointer: pointer,
        kind: ui.PointerDeviceKind.touch,
        position: position,
      ),
    );
    _active.remove(pointer);
  }

  void _checkReady() {
    if (_disposed) {
      throw const UiAutomationError(
        'disposed',
        'UI automation has been disposed',
      );
    }
  }

  void _validatePoint(int viewId, ui.Offset point, String name) {
    if (!point.dx.isFinite || !point.dy.isFinite) {
      throw UiAutomationError(
        'invalid_argument',
        '$name must contain finite coordinates',
      );
    }
    final size = _viewSize(viewId);
    if (size == null) {
      throw UiAutomationError(
        'view_not_found',
        'no Flutter view has id $viewId',
      );
    }
    if (point.dx < 0 ||
        point.dy < 0 ||
        point.dx >= size.width ||
        point.dy >= size.height) {
      throw UiAutomationError(
        'point_out_of_bounds',
        '$name is outside Flutter view $viewId',
        {
          'x': point.dx,
          'y': point.dy,
          'width': size.width,
          'height': size.height,
        },
      );
    }
  }

  void _validateGesture(Duration duration, int steps, Duration maxDuration) {
    if (duration <= Duration.zero || duration > maxDuration) {
      throw UiAutomationError(
        'invalid_argument',
        'duration must be between 1 and ${maxDuration.inMilliseconds} ms',
      );
    }
    if (steps < 1 || steps > 120) {
      throw const UiAutomationError(
        'invalid_argument',
        'steps must be between 1 and 120',
      );
    }
  }
}

Duration _stepDuration(Duration duration, int steps) {
  final micros = duration.inMicroseconds ~/ steps;
  return Duration(microseconds: micros < 1 ? 1 : micros);
}

ui.Size? _bindingViewSize(int viewId) {
  for (final view in WidgetsBinding.instance.platformDispatcher.views) {
    if (view.viewId == viewId) {
      return view.physicalSize / view.devicePixelRatio;
    }
  }
  return null;
}
