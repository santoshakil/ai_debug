import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

import 'gesture_driver.dart';
import 'models.dart';
import 'snapshotter.dart';

class UiAutomationController {
  UiAutomationController({
    this.config = const UiAutomationConfig(),
    UiSnapshotter? snapshotter,
    UiGestureDriver? gestures,
  }) : snapshotter = snapshotter ?? UiSnapshotter(config),
       gestures = gestures ?? UiGestureDriver() {
    config.validate();
  }

  final UiAutomationConfig config;
  final UiSnapshotter snapshotter;
  final UiGestureDriver gestures;
  final _gate = _SerialGate();
  final _cancellation = UiCancellation();
  var _disposed = false;
  Future<void>? _disposeFuture;

  bool get isDisposed => _disposed;

  Map<String, Object?> capabilities() => {
    'ok': true,
    'enabled': config.enabled && !_disposed,
    'input': config.allowInput,
    'raw_coordinates': config.allowRawCoordinates,
    'text_field_values': config.includeTextFieldValues,
    'snapshot_source': 'flutter_semantics',
    'operations': const [
      'snapshot',
      'find',
      'activate',
      'tap',
      'double_tap',
      'long_press',
      'drag',
      'pinch',
      'scroll',
      'scroll_until',
      'wait',
      'run',
    ],
    'limits': {
      'max_nodes': config.limits.maxNodes,
      'max_string_length': config.limits.maxStringLength,
      'max_wait_ms': config.limits.maxWait.inMilliseconds,
      'max_gesture_ms': config.limits.maxGesture.inMilliseconds,
      'max_run_steps': config.limits.maxRunSteps,
      'max_scrolls': config.limits.maxScrolls,
    },
    'limitations': const [
      'Flutter UI only',
      'system dialogs and software keyboard are not controlled',
      'platform-view internals are not visible',
      'custom-painted controls need semantics',
      'lazy children must be built before they can be found',
    ],
  };

  Future<Map<String, Object?>> snapshot({int? maxNodes, int? maxStringLength}) {
    return _gate.run(() async {
      _checkAvailable();
      final value = await snapshotter.snapshot(
        maxNodes: maxNodes,
        maxStringLength: maxStringLength,
      );
      return value.toJson();
    });
  }

  Future<Map<String, Object?>> find(UiSelector selector, {int limit = 20}) {
    return _gate.run(() => _find(selector, limit: limit));
  }

  Future<Map<String, Object?>> _find(
    UiSelector selector, {
    int limit = 20,
  }) async {
    _checkAvailable();
    _validateSelector(selector);
    if (limit < 1 || limit > 100) {
      throw const UiAutomationError(
        'invalid_argument',
        'limit must be between 1 and 100',
      );
    }
    final snapshot = await snapshotter.snapshot();
    final matches = snapshot.find(selector);
    return {
      'ok': true,
      'snapshot_id': snapshot.id,
      'count': matches.length,
      'truncated': snapshot.truncated || matches.length > limit,
      'matches': matches.take(limit).map((node) => node.toJson()).toList(),
    };
  }

  Future<Map<String, Object?>> activate(
    UiSelector selector,
    String action, {
    String? text,
    int? base,
    int? extent,
  }) {
    return _gate.run(
      () => _activate(selector, action, text: text, base: base, extent: extent),
    );
  }

  Future<Map<String, Object?>> tap(UiSelector selector) {
    return _gate.run(() => _tap(selector));
  }

  Future<Map<String, Object?>> doubleTap(
    UiSelector selector, {
    Duration interval = const Duration(milliseconds: 80),
  }) {
    return _gate.run(() => _doubleTap(selector, interval));
  }

  Future<Map<String, Object?>> longPress({
    UiSelector? selector,
    int? viewId,
    double? x,
    double? y,
    Duration? hold,
  }) {
    return _gate.run(
      () => _longPress(
        selector: selector,
        viewId: viewId,
        x: x,
        y: y,
        hold: hold ?? Duration(milliseconds: _longPressDurationDefault),
      ),
    );
  }

  Future<Map<String, Object?>> drag({
    UiSelector? selector,
    int? viewId,
    double? x,
    double? y,
    required double dx,
    required double dy,
    Duration duration = const Duration(milliseconds: 200),
    int steps = 12,
    Duration holdStart = Duration.zero,
    Duration holdEnd = Duration.zero,
  }) {
    return _gate.run(
      () => _drag(
        selector: selector,
        viewId: viewId,
        x: x,
        y: y,
        dx: dx,
        dy: dy,
        duration: duration,
        steps: steps,
        holdStart: holdStart,
        holdEnd: holdEnd,
      ),
    );
  }

  Future<Map<String, Object?>> pinch({
    UiSelector? selector,
    int? viewId,
    double? x,
    double? y,
    required double scale,
    double startSpan = 80,
    Duration duration = const Duration(milliseconds: 240),
    int steps = 12,
  }) {
    return _gate.run(
      () => _pinch(
        selector: selector,
        viewId: viewId,
        x: x,
        y: y,
        scale: scale,
        startSpan: startSpan,
        duration: duration,
        steps: steps,
      ),
    );
  }

  Future<Map<String, Object?>> scroll({
    UiSelector? selector,
    required String direction,
    int count = 1,
  }) {
    return _gate.run(
      () => _scroll(selector: selector, direction: direction, count: count),
    );
  }

  Future<Map<String, Object?>> scrollUntil({
    required UiSelector target,
    UiSelector? scrollable,
    required String direction,
    int maxScrolls = 10,
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _gate.run(
      () => _scrollUntil(
        target: target,
        scrollable: scrollable,
        direction: direction,
        maxScrolls: maxScrolls,
        timeout: timeout,
      ),
    );
  }

  Future<Map<String, Object?>> wait({
    required UiSelector selector,
    bool absent = false,
    Duration timeout = const Duration(seconds: 8),
    Duration poll = const Duration(milliseconds: 100),
    Duration stable = Duration.zero,
  }) {
    return _gate.run(
      () => _wait(
        selector: selector,
        absent: absent,
        timeout: timeout,
        poll: poll,
        stable: stable,
      ),
    );
  }

  Future<Map<String, Object?>> run(
    List<Map<String, dynamic>> steps, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return _gate.run(() => _run(steps, timeout));
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _cancellation.cancel();
    gestures.dispose();
    await _gate.idle;
  }

  Future<Map<String, Object?>> _activate(
    UiSelector selector,
    String action, {
    String? text,
    int? base,
    int? extent,
  }) async {
    _checkInput();
    _cancellation.check();
    final semanticsAction = uiActionNames[action];
    if (semanticsAction == null) {
      throw UiAutomationError('invalid_action', 'unknown action: $action');
    }
    if (action == 'setText') {
      // flutter only exposes setText on a focused field; focus first when needed
      final needsFocus = await snapshotter.inspect((inspection) async {
        final target = _one(inspection, selector);
        if (target.node.actions.contains('setText') ||
            !target.node.textField ||
            target.node.readOnly) {
          return false;
        }
        final focusAction = target.node.actions.contains('focus')
            ? 'focus'
            : target.node.actions.contains('tap')
            ? 'tap'
            : null;
        if (focusAction == null) {
          return false;
        }
        target.owner.performAction(
          target.semanticsNode.id,
          uiActionNames[focusAction]!,
          null,
        );
        return true;
      });
      if (needsFocus) {
        await _afterAction();
      }
    }
    return snapshotter.inspect((inspection) async {
      final target = _one(inspection, selector);
      _checkTarget(target.node, action);
      final argument = _actionArgument(
        action,
        target.node,
        text: text,
        base: base,
        extent: extent,
      );
      target.owner.performAction(
        target.semanticsNode.id,
        semanticsAction,
        argument,
      );
      await _afterAction();
      return {
        'ok': true,
        'dispatched': true,
        'mode': 'semantics',
        'action': action,
        'target': _brief(target.node),
      };
    });
  }

  Future<Map<String, Object?>> _tap(UiSelector selector) async {
    _checkInput();
    _cancellation.check();
    final target = await snapshotter.inspect(
      (inspection) => _one(inspection, selector),
    );
    _checkTarget(target.node, 'tap');
    await gestures.tap(
      viewId: target.node.viewId,
      position: target.node.logicalRect.center,
      cancellation: _cancellation,
      maxDuration: config.limits.maxGesture,
    );
    await _afterAction();
    return {
      'ok': true,
      'dispatched': true,
      'mode': 'pointer',
      'target': _brief(target.node),
    };
  }

  Future<Map<String, Object?>> _doubleTap(
    UiSelector selector,
    Duration interval,
  ) async {
    _checkInput();
    _cancellation.check();
    final target = await snapshotter.inspect(
      (inspection) => _one(inspection, selector),
    );
    _checkVisibleTarget(target.node);
    await gestures.doubleTap(
      viewId: target.node.viewId,
      position: target.node.logicalRect.center,
      interval: interval,
      maxDuration: config.limits.maxGesture,
      cancellation: _cancellation,
    );
    await _afterAction();
    return {
      'ok': true,
      'dispatched': true,
      'mode': 'pointer',
      'gesture': 'double_tap',
      'interval_ms': interval.inMilliseconds,
      'target': _brief(target.node),
    };
  }

  Future<Map<String, Object?>> _longPress({
    UiSelector? selector,
    int? viewId,
    double? x,
    double? y,
    required Duration hold,
  }) async {
    _checkInput();
    _cancellation.check();
    late final int targetViewId;
    late final ui.Offset position;
    UiNode? targetNode;
    if (selector != null) {
      if (viewId != null || x != null || y != null) {
        throw const UiAutomationError(
          'invalid_argument',
          'selector cannot be combined with view_id, x, or y',
        );
      }
      final target = await snapshotter.inspect(
        (inspection) => _one(inspection, selector),
      );
      _checkVisibleTarget(target.node);
      targetViewId = target.node.viewId;
      position = target.node.logicalRect.center;
      targetNode = target.node;
    } else {
      if (!config.allowRawCoordinates) {
        throw const UiAutomationError(
          'capability_disabled',
          'raw coordinate input is disabled',
        );
      }
      if (viewId == null || x == null || y == null) {
        throw const UiAutomationError(
          'invalid_argument',
          'view_id, x, and y are required without a selector',
        );
      }
      targetViewId = viewId;
      position = ui.Offset(x, y);
    }
    await gestures.tap(
      viewId: targetViewId,
      position: position,
      hold: hold,
      maxDuration: config.limits.maxGesture,
      cancellation: _cancellation,
    );
    await _afterAction();
    return {
      'ok': true,
      'dispatched': true,
      'mode': 'pointer',
      'gesture': 'long_press',
      'view_id': targetViewId,
      'position': {'x': position.dx, 'y': position.dy},
      'hold_ms': hold.inMilliseconds,
      if (targetNode != null) 'target': _brief(targetNode),
    };
  }

  Future<Map<String, Object?>> _drag({
    UiSelector? selector,
    int? viewId,
    double? x,
    double? y,
    required double dx,
    required double dy,
    required Duration duration,
    required int steps,
    required Duration holdStart,
    required Duration holdEnd,
  }) async {
    _checkInput();
    _cancellation.check();
    late final int targetViewId;
    late final ui.Offset start;
    UiNode? targetNode;
    if (selector != null) {
      if (viewId != null || x != null || y != null) {
        throw const UiAutomationError(
          'invalid_argument',
          'selector cannot be combined with view_id, x, or y',
        );
      }
      final target = await snapshotter.inspect(
        (inspection) => _one(inspection, selector),
      );
      if (!target.node.visible) {
        throw const UiAutomationError(
          'target_not_visible',
          'target is not visible',
        );
      }
      targetViewId = target.node.viewId;
      start = target.node.logicalRect.center;
      targetNode = target.node;
    } else {
      if (!config.allowRawCoordinates) {
        throw const UiAutomationError(
          'capability_disabled',
          'raw coordinate input is disabled',
        );
      }
      if (viewId == null || x == null || y == null) {
        throw const UiAutomationError(
          'invalid_argument',
          'view_id, x, and y are required without a selector',
        );
      }
      targetViewId = viewId;
      start = ui.Offset(x, y);
    }
    await gestures.drag(
      viewId: targetViewId,
      start: start,
      delta: ui.Offset(dx, dy),
      duration: duration,
      steps: steps,
      maxDuration: config.limits.maxGesture,
      cancellation: _cancellation,
      holdStart: holdStart,
      holdEnd: holdEnd,
    );
    await _afterAction();
    return {
      'ok': true,
      'dispatched': true,
      'mode': 'pointer',
      'view_id': targetViewId,
      'start': {'x': start.dx, 'y': start.dy},
      'delta': {'dx': dx, 'dy': dy},
      'duration_ms': duration.inMilliseconds,
      if (targetNode != null) 'target': _brief(targetNode),
    };
  }

  Future<Map<String, Object?>> _pinch({
    UiSelector? selector,
    int? viewId,
    double? x,
    double? y,
    required double scale,
    required double startSpan,
    required Duration duration,
    required int steps,
  }) async {
    _checkInput();
    _cancellation.check();
    late final int targetViewId;
    late final ui.Offset center;
    UiNode? targetNode;
    if (selector != null) {
      if (viewId != null || x != null || y != null) {
        throw const UiAutomationError(
          'invalid_argument',
          'selector cannot be combined with view_id, x, or y',
        );
      }
      final target = await snapshotter.inspect(
        (inspection) => _one(inspection, selector),
      );
      _checkVisibleTarget(target.node);
      targetViewId = target.node.viewId;
      center = target.node.logicalRect.center;
      targetNode = target.node;
    } else {
      if (!config.allowRawCoordinates) {
        throw const UiAutomationError(
          'capability_disabled',
          'raw coordinate input is disabled',
        );
      }
      if (viewId == null || x == null || y == null) {
        throw const UiAutomationError(
          'invalid_argument',
          'view_id, x, and y are required without a selector',
        );
      }
      targetViewId = viewId;
      center = ui.Offset(x, y);
    }
    await gestures.pinch(
      viewId: targetViewId,
      center: center,
      startSpan: startSpan,
      scale: scale,
      duration: duration,
      steps: steps,
      maxDuration: config.limits.maxGesture,
      cancellation: _cancellation,
    );
    await _afterAction();
    return {
      'ok': true,
      'dispatched': true,
      'mode': 'pointer',
      'gesture': 'pinch',
      'view_id': targetViewId,
      'center': {'x': center.dx, 'y': center.dy},
      'start_span': startSpan,
      'scale': scale,
      'duration_ms': duration.inMilliseconds,
      if (targetNode != null) 'target': _brief(targetNode),
    };
  }

  Future<Map<String, Object?>> _scroll({
    UiSelector? selector,
    required String direction,
    required int count,
  }) async {
    _checkInput();
    if (count < 1 || count > config.limits.maxScrolls) {
      throw UiAutomationError(
        'invalid_argument',
        'count must be between 1 and ${config.limits.maxScrolls}',
      );
    }
    final action = _scrollAction(direction);
    UiNode? last;
    for (var i = 0; i < count; i++) {
      _cancellation.check();
      last = await _performScroll(selector, action);
    }
    return {
      'ok': true,
      'dispatched': count,
      'direction': direction,
      if (last != null) 'target': _brief(last),
    };
  }

  Future<Map<String, Object?>> _scrollUntil({
    required UiSelector target,
    UiSelector? scrollable,
    required String direction,
    required int maxScrolls,
    required Duration timeout,
  }) async {
    _checkInput();
    _validateSelector(target);
    if (scrollable != null) _validateSelector(scrollable);
    _validateTimeout(timeout);
    if (maxScrolls < 1 || maxScrolls > config.limits.maxScrolls) {
      throw UiAutomationError(
        'invalid_argument',
        'max_scrolls must be between 1 and ${config.limits.maxScrolls}',
      );
    }
    final action = _scrollAction(direction);
    final watch = Stopwatch()..start();
    double? priorPosition;
    var performed = 0;
    for (var i = 0; i <= maxScrolls; i++) {
      _cancellation.check();
      final found = await snapshotter.snapshot();
      final matches = found.find(target);
      final nth = target.nth;
      final picked = nth != null
          ? (nth < matches.length ? matches[nth] : null)
          : (matches.length == 1 ? matches.single : null);
      if (picked != null) {
        return {
          'ok': true,
          'found': true,
          'scrolls': i,
          'elapsed_ms': watch.elapsedMilliseconds,
          'target': _brief(picked),
        };
      }
      if (nth == null && matches.length > 1) {
        throw UiAutomationError(
          'ambiguous_target',
          'target matched ${matches.length} nodes',
          _candidates(matches),
        );
      }
      if (i == maxScrolls || watch.elapsed >= timeout) break;
      final node = await _performScroll(scrollable, action);
      performed++;
      final position = node.scrollPosition;
      if (position != null && position == priorPosition) {
        throw UiAutomationError(
          'scroll_end_reached',
          'scroll position did not change',
          {'scrolls': performed, 'elapsed_ms': watch.elapsedMilliseconds},
        );
      }
      priorPosition = position;
    }
    throw UiAutomationError(
      'target_not_found',
      'target was not found before the scroll limit',
      {'scrolls': performed, 'elapsed_ms': watch.elapsedMilliseconds},
    );
  }

  Future<UiNode> _performScroll(UiSelector? selector, String action) async {
    return snapshotter.inspect((inspection) async {
      final effective = selector ?? UiSelector(action: action);
      final target = _one(inspection, effective);
      _checkTarget(target.node, action);
      target.owner.performAction(
        target.semanticsNode.id,
        uiActionNames[action]!,
      );
      await _afterAction();
      return target.node;
    });
  }

  Future<Map<String, Object?>> _wait({
    required UiSelector selector,
    required bool absent,
    required Duration timeout,
    required Duration poll,
    required Duration stable,
  }) async {
    _checkAvailable();
    _validateSelector(selector);
    _validateTimeout(timeout);
    if (poll < const Duration(milliseconds: 30) ||
        poll > const Duration(seconds: 5)) {
      throw const UiAutomationError(
        'invalid_argument',
        'poll must be between 30 and 5000 ms',
      );
    }
    if (stable < Duration.zero || stable > timeout) {
      throw const UiAutomationError(
        'invalid_argument',
        'stable must be between 0 and timeout',
      );
    }
    final watch = Stopwatch()..start();
    Duration? stableSince;
    while (true) {
      _cancellation.check();
      final snapshot = await snapshotter.snapshot();
      final matches = snapshot.find(selector);
      final holds = absent ? matches.isEmpty : matches.isNotEmpty;
      if (holds) {
        stableSince ??= watch.elapsed;
        if (watch.elapsed - stableSince >= stable) {
          return {
            'ok': true,
            'condition': absent ? 'absent' : 'present',
            'elapsed_ms': watch.elapsedMilliseconds,
            'count': matches.length,
            'matches': matches.take(10).map((node) => node.toJson()).toList(),
          };
        }
      } else {
        stableSince = null;
      }
      if (watch.elapsed >= timeout) {
        throw UiAutomationError(
          'wait_timeout',
          'condition did not hold before timeout',
          {
            'condition': absent ? 'absent' : 'present',
            'elapsed_ms': watch.elapsedMilliseconds,
            'count': matches.length,
          },
        );
      }
      final remaining = timeout - watch.elapsed;
      await _cancellation.delay(remaining < poll ? remaining : poll);
    }
  }

  Future<Map<String, Object?>> _run(
    List<Map<String, dynamic>> steps,
    Duration timeout,
  ) async {
    _checkInput();
    _validateTimeout(timeout);
    if (steps.isEmpty || steps.length > config.limits.maxRunSteps) {
      throw UiAutomationError(
        'invalid_argument',
        'steps must contain 1 to ${config.limits.maxRunSteps} entries',
      );
    }
    final watch = Stopwatch()..start();
    final results = <Map<String, Object?>>[];
    for (var index = 0; index < steps.length; index++) {
      _cancellation.check();
      if (watch.elapsed >= timeout) {
        throw UiAutomationError(
          'run_timeout',
          'sequence timed out before step $index',
          {'completed': results.length, 'results': results},
        );
      }
      late final Map<String, Object?> result;
      try {
        result = await _runStep(steps[index], timeout - watch.elapsed);
      } on UiAutomationError catch (error) {
        throw UiAutomationError(
          'run_step_failed',
          'step $index failed: ${error.message}',
          {
            'failed_step': index,
            'completed': results.length,
            'cause': error.toJson()['error'],
            'results': results,
          },
        );
      }
      if (watch.elapsed >= timeout) {
        throw UiAutomationError(
          'run_timeout',
          'sequence timed out during step $index',
          {
            'failed_step': index,
            'completed': results.length,
            'results': results,
          },
        );
      }
      results.add({'index': index, ...result});
    }
    return {
      'ok': true,
      'completed': results.length,
      'elapsed_ms': watch.elapsedMilliseconds,
      'results': results,
    };
  }

  Future<Map<String, Object?>> _runStep(
    Map<String, dynamic> step,
    Duration remaining,
  ) async {
    final op = step['op'];
    if (op is! String) {
      throw const UiAutomationError(
        'invalid_step',
        'each step needs a string op',
      );
    }
    _checkStepKeys(step, op);
    return switch (op) {
      'activate' => _activate(
        _selector(step),
        _string(step, 'action'),
        text: _optional<String>(step, 'text'),
        base: _optional<int>(step, 'base'),
        extent: _optional<int>(step, 'extent'),
      ),
      'tap' => _tap(_selector(step)),
      'double_tap' => _doubleTap(
        _selector(step),
        Duration(
          milliseconds:
              _optional<int>(step, 'interval_ms') ?? _doubleTapIntervalDefault,
        ),
      ),
      'long_press' => _longPress(
        selector: _optionalSelector(step),
        viewId: _optional<int>(step, 'view_id'),
        x: _optionalNumber(step, 'x'),
        y: _optionalNumber(step, 'y'),
        hold: Duration(
          milliseconds:
              _optional<int>(step, 'hold_ms') ?? _longPressDurationDefault,
        ),
      ),
      'drag' => _drag(
        selector: _optionalSelector(step),
        viewId: _optional<int>(step, 'view_id'),
        x: _optionalNumber(step, 'x'),
        y: _optionalNumber(step, 'y'),
        dx: _number(step, 'dx'),
        dy: _number(step, 'dy'),
        duration: Duration(
          milliseconds:
              _optional<int>(step, 'duration_ms') ?? _dragDurationDefault,
        ),
        steps: _optional<int>(step, 'steps') ?? 12,
        holdStart: Duration(
          milliseconds: _optional<int>(step, 'hold_start_ms') ?? 0,
        ),
        holdEnd: Duration(
          milliseconds: _optional<int>(step, 'hold_end_ms') ?? 0,
        ),
      ),
      'pinch' => _pinch(
        selector: _optionalSelector(step),
        viewId: _optional<int>(step, 'view_id'),
        x: _optionalNumber(step, 'x'),
        y: _optionalNumber(step, 'y'),
        scale: _number(step, 'scale'),
        startSpan: _optionalNumber(step, 'start_span') ?? 80,
        duration: Duration(
          milliseconds:
              _optional<int>(step, 'duration_ms') ?? _pinchDurationDefault,
        ),
        steps: _optional<int>(step, 'steps') ?? 12,
      ),
      'scroll' => _scroll(
        selector: _optionalSelector(step),
        direction: _string(step, 'direction'),
        count: _optional<int>(step, 'count') ?? 1,
      ),
      'scroll_until' => _scrollUntil(
        target: _namedSelector(step, 'target'),
        scrollable: _optionalNamedSelector(step, 'scrollable'),
        direction: _string(step, 'direction'),
        maxScrolls: _optional<int>(step, 'max_scrolls') ?? _scrollCountDefault,
        timeout: _stepTimeout(step, remaining),
      ),
      'wait' => _wait(
        selector: _selector(step),
        absent: _optional<bool>(step, 'absent') ?? false,
        timeout: _stepTimeout(step, remaining),
        poll: Duration(milliseconds: _optional<int>(step, 'poll_ms') ?? 100),
        stable: Duration(milliseconds: _optional<int>(step, 'stable_ms') ?? 0),
      ),
      _ => throw UiAutomationError('invalid_step', 'unknown step op: $op'),
    };
  }

  UiNodeHandle _one(UiInspection inspection, UiSelector selector) {
    _validateSelector(selector);
    final matches = inspection.snapshot.find(selector);
    if (matches.isEmpty) {
      final code = inspection.snapshot.truncated
          ? 'search_truncated'
          : 'target_not_found';
      throw UiAutomationError(
        code,
        inspection.snapshot.truncated
            ? 'target was not found before the snapshot limit'
            : 'target did not match any visible node',
      );
    }
    final nth = selector.nth;
    if (nth != null) {
      if (nth >= matches.length) {
        throw UiAutomationError(
          'target_not_found',
          'nth $nth is out of range for ${matches.length} matches',
          _candidates(matches),
        );
      }
      return inspection.handleFor(matches[nth]);
    }
    if (matches.length != 1) {
      throw UiAutomationError(
        'ambiguous_target',
        'target matched ${matches.length} nodes',
        _candidates(matches),
      );
    }
    return inspection.handleFor(matches.single);
  }

  void _checkTarget(UiNode node, String action) {
    _checkVisibleTarget(node);
    if (!node.actions.contains(action)) {
      throw UiAutomationError(
        'action_not_supported',
        'target does not support $action',
        {'actions': node.actions.toList()..sort()},
      );
    }
  }

  void _checkVisibleTarget(UiNode node) {
    if (!node.visible) {
      throw const UiAutomationError(
        'target_not_visible',
        'target is not visible',
      );
    }
    if (node.enabled == false) {
      throw const UiAutomationError('target_disabled', 'target is disabled');
    }
  }

  Object? _actionArgument(
    String action,
    UiNode node, {
    String? text,
    int? base,
    int? extent,
  }) {
    switch (action) {
      case 'setText':
        if (!node.textField || node.readOnly) {
          throw const UiAutomationError(
            'invalid_target',
            'setText needs an editable text field',
          );
        }
        if (text == null) {
          throw const UiAutomationError(
            'invalid_argument',
            'text is required for setText',
          );
        }
        if (text.length > 65536) {
          throw const UiAutomationError(
            'invalid_argument',
            'text must contain at most 65536 characters',
          );
        }
        return text;
      case 'setSelection':
        if (base == null || extent == null || base < 0 || extent < 0) {
          throw const UiAutomationError(
            'invalid_argument',
            'non-negative base and extent are required for setSelection',
          );
        }
        return {'base': base, 'extent': extent};
      default:
        if (text != null || base != null || extent != null) {
          throw UiAutomationError(
            'invalid_argument',
            '$action does not accept text or selection arguments',
          );
        }
        return null;
    }
  }

  Future<void> _afterAction() async {
    _cancellation.check();
    final scheduler = SchedulerBinding.instance;
    if (!scheduler.framesEnabled) return;
    try {
      await scheduler.endOfFrame.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      throw const UiAutomationError(
        'frame_timeout',
        'Flutter did not finish a frame after the action',
      );
    }
    _cancellation.check();
  }

  String _scrollAction(String direction) => switch (direction) {
    'down' => 'scrollUp',
    'up' => 'scrollDown',
    'right' => 'scrollLeft',
    'left' => 'scrollRight',
    _ => throw const UiAutomationError(
      'invalid_argument',
      'direction must be down, up, right, or left',
    ),
  };

  void _checkAvailable() {
    if (_disposed) {
      throw const UiAutomationError(
        'disposed',
        'UI automation has been disposed',
      );
    }
    if (!config.enabled) {
      throw const UiAutomationError(
        'capability_disabled',
        'UI automation is disabled',
      );
    }
  }

  void _checkInput() {
    _checkAvailable();
    if (!config.allowInput) {
      throw const UiAutomationError(
        'capability_disabled',
        'UI input is disabled',
      );
    }
  }

  void _validateTimeout(Duration timeout) {
    if (timeout < Duration.zero || timeout > config.limits.maxWait) {
      throw UiAutomationError(
        'invalid_argument',
        'timeout must be between 0 and ${config.limits.maxWait.inMilliseconds} ms',
      );
    }
  }

  void _validateSelector(UiSelector selector) {
    if (!selector.hasConstraint) {
      throw const UiAutomationError(
        'invalid_selector',
        'selector must contain at least one match field',
      );
    }
    if (selector.action != null &&
        !uiActionNames.containsKey(selector.action)) {
      throw UiAutomationError(
        'invalid_selector',
        'unknown action: ${selector.action}',
      );
    }
    if (selector.id != null && selector.viewId == null) {
      throw const UiAutomationError(
        'invalid_selector',
        'view_id is required with id',
      );
    }
    if ((selector.id != null && selector.id! < 0) ||
        (selector.viewId != null && selector.viewId! < 0)) {
      throw const UiAutomationError(
        'invalid_selector',
        'id and view_id must not be negative',
      );
    }
    for (final value in [
      selector.identifier,
      selector.label,
      selector.text,
      selector.value,
      selector.hint,
      selector.tooltip,
    ]) {
      if (value != null && value.length > config.limits.maxStringLength) {
        throw UiAutomationError(
          'invalid_selector',
          'selector strings must contain at most ${config.limits.maxStringLength} characters',
        );
      }
      if (value != null && value.isEmpty) {
        throw const UiAutomationError(
          'invalid_selector',
          'selector strings must not be empty',
        );
      }
    }
  }

  int get _dragDurationDefault => config.limits.maxGesture.inMilliseconds < 200
      ? config.limits.maxGesture.inMilliseconds
      : 200;

  int get _pinchDurationDefault => config.limits.maxGesture.inMilliseconds < 240
      ? config.limits.maxGesture.inMilliseconds
      : 240;

  int get _longPressDurationDefault =>
      config.limits.maxGesture.inMilliseconds < 600
      ? config.limits.maxGesture.inMilliseconds
      : 600;

  int get _doubleTapIntervalDefault {
    final max = config.limits.maxGesture.inMilliseconds - 80;
    return max < 80 ? max : 80;
  }

  int get _scrollCountDefault =>
      config.limits.maxScrolls < 10 ? config.limits.maxScrolls : 10;
}

class _SerialGate {
  Future<void> _tail = Future<void>.value();
  var _pending = 0;

  Future<void> get idle => _pending == 0 ? Future<void>.value() : _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final before = _tail;
    final released = Completer<void>.sync();
    _pending++;
    _tail = released.future;
    return () async {
      await before;
      try {
        return await action();
      } finally {
        _pending--;
        released.complete();
      }
    }();
  }
}

List<Map<String, Object?>> _candidates(List<UiNode> nodes) =>
    nodes.take(10).map((node) => _brief(node)).toList(growable: false);

Map<String, Object?> _brief(UiNode node) => {
  'id': node.id,
  'view_id': node.viewId,
  if (node.identifier != null) 'identifier': node.identifier,
  if (node.label != null) 'label': node.label,
  'rect': node.logicalRect.toJson(),
};

UiSelector _selector(Map<String, dynamic> json) {
  final value = json['selector'];
  if (value is! Map) {
    throw const UiAutomationError('invalid_step', 'selector is required');
  }
  return UiSelector.fromJson(Map<String, dynamic>.from(value));
}

UiSelector? _optionalSelector(Map<String, dynamic> json) {
  final value = json['selector'];
  if (value == null) return null;
  if (value is! Map) {
    throw const UiAutomationError('invalid_step', 'selector must be an object');
  }
  return UiSelector.fromJson(Map<String, dynamic>.from(value));
}

UiSelector _namedSelector(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value is! Map) {
    throw UiAutomationError('invalid_step', '$name is required');
  }
  return UiSelector.fromJson(Map<String, dynamic>.from(value));
}

UiSelector? _optionalNamedSelector(Map<String, dynamic> json, String name) {
  if (json[name] == null) return null;
  return _namedSelector(json, name);
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw UiAutomationError('invalid_step', '$key must be a string');
  }
  if (value.length > 256) {
    throw UiAutomationError(
      'invalid_step',
      '$key must contain at most 256 characters',
    );
  }
  return value;
}

double _number(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw UiAutomationError('invalid_step', '$key must be a number');
  }
  return value.toDouble();
}

double? _optionalNumber(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num) {
    throw UiAutomationError('invalid_step', '$key must be a number');
  }
  return value.toDouble();
}

T? _optional<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! T) {
    throw UiAutomationError('invalid_step', '$key has the wrong type');
  }
  return value;
}

Duration _stepTimeout(Map<String, dynamic> step, Duration remaining) {
  final value = _optional<int>(step, 'timeout_ms');
  final requested = Duration(milliseconds: value ?? 8000);
  return requested < remaining ? requested : remaining;
}

void _checkStepKeys(Map<String, dynamic> step, String op) {
  final allowed = switch (op) {
    'activate' => const {'op', 'selector', 'action', 'text', 'base', 'extent'},
    'tap' => const {'op', 'selector'},
    'double_tap' => const {'op', 'selector', 'interval_ms'},
    'long_press' => const {'op', 'selector', 'view_id', 'x', 'y', 'hold_ms'},
    'drag' => const {
      'op',
      'selector',
      'view_id',
      'x',
      'y',
      'dx',
      'dy',
      'duration_ms',
      'steps',
    },
    'pinch' => const {
      'op',
      'selector',
      'view_id',
      'x',
      'y',
      'scale',
      'start_span',
      'duration_ms',
      'steps',
    },
    'scroll' => const {'op', 'selector', 'direction', 'count'},
    'scroll_until' => const {
      'op',
      'target',
      'scrollable',
      'direction',
      'max_scrolls',
      'timeout_ms',
    },
    'wait' => const {
      'op',
      'selector',
      'absent',
      'timeout_ms',
      'poll_ms',
      'stable_ms',
    },
    _ => null,
  };
  if (allowed == null) {
    throw UiAutomationError('invalid_step', 'unknown step op: $op');
  }
  final extra = step.keys.where((key) => !allowed.contains(key)).toList();
  if (extra.isNotEmpty) {
    throw UiAutomationError(
      'invalid_step',
      'unknown $op fields: ${extra.join(', ')}',
    );
  }
}
