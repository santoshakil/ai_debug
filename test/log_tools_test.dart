import 'package:ai_debug/src/builtins/log_tools.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('emits one bounded marker only with controls', () async {
    final registry = CommandRegistry();
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    addTearDown(registry.dispose);

    registerLogTools(registry, controls: true);
    final result = await registry.dispatch('logs.emit', const {
      'level': 'WARNING',
      'logger': 'test.marker',
      'message': 'ready',
    });

    expect(result.json, {
      'ok': true,
      'level': 'WARNING',
      'logger': 'test.marker',
    });
    expect(records.single.loggerName, 'test.marker');
    expect(records.single.message, 'ready');
    expect(registry.get('logs.emit')!.annotations?['openWorldHint'], isTrue);
  });

  test('does not register emit without runtime controls', () {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);

    registerLogTools(registry, controls: false);

    expect(registry.get('logs.emit'), isNull);
  });
}
