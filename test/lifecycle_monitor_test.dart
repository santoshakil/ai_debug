import 'package:ai_debug/src/observability/lifecycle_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lifecycle history is bounded and supports cursors', () {
    final monitor = LifecycleMonitor(capacity: 2)..start();
    monitor.didChangeAppLifecycleState(AppLifecycleState.inactive);
    monitor.didChangeAppLifecycleState(AppLifecycleState.paused);
    monitor.didChangeAppLifecycleState(AppLifecycleState.resumed);

    expect(monitor.length, 2);
    expect(monitor.dropped, greaterThanOrEqualTo(1));
    final events = monitor.history();
    expect(events.map((event) => event.state), [
      AppLifecycleState.paused,
      AppLifecycleState.resumed,
    ]);
    expect(monitor.history(after: events.first.sequence), hasLength(1));
    monitor.dispose();
    expect(monitor.isStarted, isFalse);
  });

  test('start and dispose are repeatable', () {
    final monitor = LifecycleMonitor();
    monitor.start();
    monitor.start();
    monitor.dispose();
    monitor.dispose();

    expect(monitor.isStarted, isFalse);
    expect(monitor.length, 0);
  });
}
