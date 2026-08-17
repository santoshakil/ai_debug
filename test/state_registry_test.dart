import 'dart:async';

import 'package:ai_debug/src/state/state_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot applies redaction and tracks status', () async {
    final registry = StateRegistry();
    registry.add(
      StateSource(
        name: 'auth',
        snapshot: () => {'token': 'secret', 'user': 'one'},
        redactor: (value) => {'user': (value as Map)['user']},
      ),
    );

    final value = await registry.read('auth');

    expect(value.value, {'user': 'one'});
    expect(value.toJson().toString(), isNot(contains('secret')));
    expect(registry.sources.single.lastReadAt, isNotNull);
  });

  test('sensitive source is hidden without a redactor', () async {
    final registry = StateRegistry();
    registry.add(
      StateSource(name: 'secret', snapshot: () => 'token', sensitive: true),
    );

    expect((await registry.read('secret')).value, '[redacted]');
  });

  test('change stream records bounded cursor history', () async {
    final changes = StreamController<Object?>();
    final registry = StateRegistry(capacity: 2);
    registry.add(
      StateSource(
        name: 'timeline',
        snapshot: () => const {},
        changes: changes.stream,
      ),
    );

    changes.add(1);
    changes.add(2);
    changes.add(3);
    await Future<void>.delayed(Duration.zero);

    expect(registry.eventCount, 2);
    expect(registry.dropped, 1);
    expect(registry.history().map((event) => event.value), [2, 3]);
    expect(registry.history(after: 2).single.value, 3);
    await registry.dispose();
    expect(changes.hasListener, isFalse);
    await changes.close();
  });

  test('snapshot timeout is recorded and rethrown', () async {
    final registry = StateRegistry();
    final pending = Completer<Object?>();
    registry.add(
      StateSource(
        name: 'slow',
        snapshot: () => pending.future,
        timeout: const Duration(milliseconds: 1),
      ),
    );

    await expectLater(registry.read('slow'), throwsA(isA<TimeoutException>()));
    expect(registry.sources.single.lastError, contains('TimeoutException'));
    expect(registry.history().single.error, contains('TimeoutException'));
  });

  test('duplicate source is rejected', () {
    final registry = StateRegistry();
    final source = StateSource(name: 'same', snapshot: () => null);
    registry.add(source);

    expect(() => registry.add(source), throwsStateError);
  });

  test('failed stream listen does not register the source', () {
    final registry = StateRegistry();

    expect(
      () => registry.add(
        StateSource(
          name: 'failed',
          snapshot: () => null,
          changes: _ThrowingStream(),
        ),
      ),
      throwsStateError,
    );
    expect(registry.length, 0);

    registry.add(StateSource(name: 'failed', snapshot: () => null));
    expect(registry.length, 1);
  });

  test('records a synchronous on-listen change', () async {
    late final StreamController<Object?> changes;
    changes = StreamController<Object?>.broadcast(
      sync: true,
      onListen: () => changes.add('first'),
    );
    final registry = StateRegistry();

    registry.add(
      StateSource(name: 'sync', snapshot: () => null, changes: changes.stream),
    );

    expect(registry.history().single.value, 'first');
    await registry.dispose();
    await changes.close();
  });

  test('sensitive source errors do not expose details', () async {
    final changes = StreamController<Object?>();
    final registry = StateRegistry();
    registry.add(
      StateSource(
        name: 'secret',
        snapshot: () => throw StateError('snapshot token'),
        changes: changes.stream,
        sensitive: true,
      ),
    );

    await expectLater(
      registry.read('secret'),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString().contains('state source failed') &&
              !error.toString().contains('snapshot token'),
        ),
      ),
    );
    changes.addError(StateError('stream token'));
    await Future<void>.delayed(Duration.zero);

    final output = [
      registry.sources.single.toJson(),
      for (final event in registry.history()) event.toJson(),
    ].toString();
    expect(output, contains('state source failed'));
    expect(output, isNot(contains('snapshot token')));
    expect(output, isNot(contains('stream token')));
    await registry.dispose();
    await changes.close();
  });

  test('redactor errors are replaced before read or record returns', () async {
    final changes = StreamController<Object?>();
    final registry = StateRegistry();
    registry.add(
      StateSource(
        name: 'redacted',
        snapshot: () => 'read secret',
        changes: changes.stream,
        redactor: (_) => throw StateError('redactor secret'),
      ),
    );

    await expectLater(
      registry.read('redacted'),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString().contains('state redaction failed') &&
              !error.toString().contains('redactor secret'),
        ),
      ),
    );
    expect(
      () => registry.record('redacted', 'change secret'),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString().contains('state redaction failed') &&
              !error.toString().contains('redactor secret'),
        ),
      ),
    );
    changes.add('stream secret');
    await Future<void>.delayed(Duration.zero);

    final output = [
      registry.sources.single.toJson(),
      for (final event in registry.history()) event.toJson(),
    ].toString();
    expect(output, contains('state redaction failed'));
    expect(output, isNot(contains('read secret')));
    expect(output, isNot(contains('change secret')));
    expect(output, isNot(contains('stream secret')));
    expect(output, isNot(contains('redactor secret')));
    expect(registry.sources.single.version, 0);
    await registry.dispose();
    await changes.close();
  });

  test('bad source error text is stored safely', () async {
    final error = _BadText();
    final changes = StreamController<Object?>();
    final registry = StateRegistry();
    registry.add(
      StateSource(
        name: 'broken',
        snapshot: () => throw error,
        changes: changes.stream,
      ),
    );

    Object? caught;
    try {
      await registry.read('broken');
    } catch (value) {
      caught = value;
    }
    expect(caught, same(error));
    expect(registry.history().single.error, '<unavailable>');

    changes.addError(_BadText());
    await Future<void>.delayed(Duration.zero);
    expect(registry.history().last.error, '<unavailable>');

    await registry.dispose();
    await changes.close();
  });
}

class _ThrowingStream extends Stream<Object?> {
  @override
  StreamSubscription<Object?> listen(
    void Function(Object? event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw StateError('listen failed');
}

class _BadText {
  @override
  String toString() => throw StateError('no text');
}
