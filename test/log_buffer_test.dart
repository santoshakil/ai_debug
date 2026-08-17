import 'package:ai_debug/src/log_buffer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('bad error text cannot escape the log listener', () {
    final buffer = DartLogBuffer();

    expect(
      () => buffer.push(
        LogRecord(Level.WARNING, 'message', 'test', _BadText(), _BadStack()),
      ),
      returnsNormally,
    );

    final record = buffer.tail().single;
    expect(record.error, '<unavailable>');
    expect(record.stackTrace, '<unavailable>');
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
