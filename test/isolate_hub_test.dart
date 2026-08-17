import 'dart:isolate';

import 'package:ai_debug/src/isolates/isolate_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client joins, reports bounded events, and exits', () async {
    final hub = IsolateHub(capacity: 2);
    hub.start();
    final client = AiDebugIsolateClient.attach(hub.sendPort, name: 'worker');
    await _tick();

    client.event('one', {'value': 1});
    client.event('two', 2);
    client.event('three', 3);
    await _tick();

    expect(hub.isolates().single.name, 'worker');
    expect(hub.history().map((event) => event.kind), ['two', 'three']);
    expect(hub.dropped, 2);

    client.dispose();
    await _tick();
    expect(hub.isolates(), isEmpty);
    await hub.dispose();
  });

  test('send port can be passed to another isolate', () async {
    final hub = IsolateHub();
    hub.start();
    final exit = ReceivePort();
    await Isolate.spawn(_worker, [hub.sendPort, exit.sendPort]);
    await exit.first;
    await _tick();

    expect(hub.history().any((event) => event.kind == 'work'), isTrue);
    await hub.dispose();
    exit.close();
  });

  test('malformed map keys are ignored', () async {
    final hub = IsolateHub();
    hub.start();

    hub.sendPort.send({
      'id': 'one',
      'name': 'worker',
      'kind': 'join',
      1: 'invalid key',
    });
    await _tick();

    expect(hub.isolates(), isEmpty);
    expect(hub.history(), isEmpty);
    await hub.dispose();
  });

  test('isolate records are bounded and stale records are pruned', () async {
    final hub = IsolateHub(
      maxIsolates: 2,
      staleAfter: const Duration(milliseconds: 200),
    );
    hub.start();

    for (final id in ['one', 'two', 'three']) {
      hub.sendPort.send({'id': id, 'name': id, 'kind': 'join'});
    }
    await _tick();

    expect(
      hub.isolates().map((isolate) => isolate.id),
      unorderedEquals(['two', 'three']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(hub.isolates(), isEmpty);
    await hub.dispose();
  });

  test('disposed client rejects events without rejoining', () async {
    final hub = IsolateHub();
    hub.start();
    final client = AiDebugIsolateClient.attach(hub.sendPort, name: 'worker');
    await _tick();

    client.dispose();
    await _tick();
    expect(() => client.event('late'), throwsStateError);
    await _tick();

    expect(hub.isolates(), isEmpty);
    expect(hub.history().any((event) => event.kind == 'late'), isFalse);
    await hub.dispose();
  });

  test('bad error and stack text are reported safely', () async {
    final hub = IsolateHub();
    hub.start();
    final client = AiDebugIsolateClient.attach(hub.sendPort, name: 'worker');
    await _tick();

    expect(() => client.error(_BadText(), _BadStack()), returnsNormally);
    await _tick();

    final event = hub.history().last;
    final data = event.data! as Map<String, Object?>;
    expect(event.kind, 'error');
    expect(data['error'], '<unavailable>');
    expect(data['stack'], '<unavailable>');

    client.dispose();
    await hub.dispose();
  });
}

void _worker(List<SendPort> ports) {
  final client = AiDebugIsolateClient.attach(ports[0], name: 'spawned');
  client.event('work', {'ok': true});
  client.dispose();
  ports[1].send(true);
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 20));

class _BadText {
  @override
  String toString() => throw StateError('no text');
}

class _BadStack implements StackTrace {
  @override
  String toString() => throw StateError('no stack');
}
