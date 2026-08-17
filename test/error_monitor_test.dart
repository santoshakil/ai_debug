import 'package:ai_debug/ai_debug.dart';
import 'package:ai_debug/src/observability/error_monitor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('error history is bounded and supports a cursor', () {
    final monitor = ErrorMonitor(capacity: 2);
    monitor.record(StateError('one'), StackTrace.empty);
    monitor.record(StateError('two'), StackTrace.empty);
    monitor.record(StateError('three'), StackTrace.empty);

    expect(monitor.length, 2);
    expect(monitor.dropped, 1);
    expect(monitor.history().map((event) => event.sequence), [2, 3]);
    expect(monitor.history(after: 2).single.error, contains('three'));
  });

  test('dispose clears captured data', () {
    final monitor = ErrorMonitor();
    monitor.record(StateError('one'), StackTrace.empty);
    monitor.dispose();

    expect(monitor.length, 0);
  });

  test('bad error and stack text are stored safely', () {
    final monitor = ErrorMonitor();

    expect(() => monitor.record(_BadText(), _BadStack()), returnsNormally);

    final event = monitor.history().single;
    expect(event.error, '<unavailable>');
    expect(event.stack, '<unavailable>');
  });

  test('public guarded errors survive bad text', () {
    var handled = 0;

    expect(
      () => AiDebug.runGuarded<void>(
        () => throw _BadText(),
        onError: (_, _) => handled++,
      ),
      returnsNormally,
    );
    expect(handled, 1);
  });

  test('a retained wrapper still forwards after dispose and restart', () {
    final saved = FlutterError.onError;
    var forwarded = 0;
    try {
      FlutterError.onError = (_) => forwarded++;
      final monitor = ErrorMonitor()..start();
      final installed = FlutterError.onError!;
      FlutterError.onError = installed;

      monitor.dispose();
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('after dispose')),
      );
      expect(forwarded, 1);
      expect(monitor.length, 0);

      monitor.start();
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('after restart')),
      );
      expect(forwarded, 2);
      expect(monitor.length, 1);
      monitor.dispose();
    } finally {
      FlutterError.onError = saved;
    }
  });

  test('capture failures do not block the app Flutter error handler', () {
    final saved = FlutterError.onError;
    var forwarded = 0;
    try {
      FlutterError.onError = (_) => forwarded++;
      final monitor = ErrorMonitor()..start();

      FlutterError.onError!(FlutterErrorDetails(exception: _BadText()));

      expect(forwarded, 1);
      expect(monitor.history().single.error, '<unavailable>');
      monitor.dispose();
    } finally {
      FlutterError.onError = saved;
    }
  });
}

class _BadText {
  @override
  String toString() => throw StateError('no text');
}

class _BadStack implements StackTrace {
  @override
  String toString() => throw StateError('no stack');
}
