import 'package:ai_debug/src/internal/json_value.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses one global item limit', () {
    final value = {
      for (var i = 0; i < 10; i++) '$i': [for (var j = 0; j < 10; j++) j],
    };

    final safe = toJsonValue(value, maxItems: 5) as Map<String, Object?>;
    expect(safe.length, lessThanOrEqualTo(6));
    expect(safe['[truncated]'], isTrue);
  });

  test('cuts cycles', () {
    final value = <Object?>[];
    value.add(value);

    expect(toJsonValue(value), ['[cycle]']);
  });

  test('uses one global string limit', () {
    final safe =
        toJsonValue(['abcdefgh', 'ijklmnop'], maxStringUnits: 10)
            as List<Object?>;

    expect(safe.first, 'abcdefgh');
    expect(safe.last, 'i…');
    expect(safe.cast<String>().fold(0, (sum, text) => sum + text.length), 10);
  });

  test('can reject values instead of truncating them', () {
    expect(
      () => toJsonValue(
        {'value': 'too long'},
        maxStringUnits: 4,
        truncate: false,
      ),
      throwsA(isA<JsonValueLimitException>()),
    );
  });

  test('bad text conversion becomes a safe JSON value', () {
    expect(toJsonValue({const _BadKey(): const _BadValue(), null: true}), {
      '<unavailable>': '<unavailable>',
      'null': true,
    });
  });
}

class _BadKey {
  const _BadKey();

  @override
  String toString() => throw StateError('no key text');
}

class _BadValue {
  const _BadValue();

  @override
  String toString() => throw StateError('no value text');
}
