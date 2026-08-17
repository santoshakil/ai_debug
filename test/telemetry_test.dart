import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_debug/src/internal/telemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('sends bounded JSON batches to a loopback collector', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.complete(jsonDecode(body) as Map<String, dynamic>);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    final telemetry = Telemetry(
      flushInterval: const Duration(hours: 1),
      captureLogs: false,
      captureLifecycle: false,
    );
    telemetry.start(
      collectorUrl: 'http://127.0.0.1:${server.port}/debug/',
      appId: 'test.app',
    );
    telemetry.emit(
      kind: 'work.done',
      payload: {'ok': true, 'time': DateTime.utc(2026)},
    );

    await telemetry.flushNow();
    final body = await received.future;
    final events = body['events'] as List<dynamic>;

    expect(events, hasLength(2));
    expect((events.last as Map<String, dynamic>)['kind'], 'work.done');
    expect(
      ((events.last as Map<String, dynamic>)['payload']
          as Map<String, dynamic>)['time'],
      '2026-01-01T00:00:00.000Z',
    );
    expect(telemetry.queueDepth, 0);
    expect(telemetry.stats['totalSent'], 2);
    await telemetry.stop();
    await server.close(force: true);
  });

  test('validates configuration and event names', () async {
    final telemetry = Telemetry(captureLogs: false, captureLifecycle: false);

    expect(
      () => telemetry.start(collectorUrl: 'http://example.com', appId: 'app'),
      throwsArgumentError,
    );
    expect(
      () => telemetry.start(
        collectorUrl: 'https://user:secret@example.com',
        appId: 'app',
      ),
      throwsArgumentError,
    );
    expect(
      () => telemetry.start(
        collectorUrl: 'https://example.com?token=secret',
        appId: 'app',
      ),
      throwsArgumentError,
    );
    expect(
      () => telemetry.start(collectorUrl: 'https://example.com', appId: ' '),
      throwsArgumentError,
    );
    telemetry.start(collectorUrl: 'https://example.com', appId: 'app');
    expect(() => telemetry.emit(kind: 'bad event'), throwsArgumentError);
    await telemetry.stop();
  });

  test('normalizes payloads and bounds the whole queue', () async {
    final cycle = <Object?>[];
    cycle.add(cycle);
    final telemetry = Telemetry(
      maxEvents: 3,
      maxQueueBytes: 700,
      maxEventBytes: 500,
      maxBatchBytes: 600,
      maxPayloadItems: 4,
      maxPayloadStringLength: 80,
      flushInterval: const Duration(hours: 1),
      captureLogs: false,
      captureLifecycle: false,
    );
    telemetry.start(collectorUrl: 'http://localhost:1', appId: 'app');
    telemetry.emit(
      kind: 'safe',
      payload: {
        'nan': double.nan,
        'cycle': cycle,
        'uri': Uri.parse('https://example.com'),
      },
    );
    for (var i = 0; i < 8; i++) {
      telemetry.emit(kind: 'item', payload: {'value': 'x' * 80, 'i': i});
    }

    expect(telemetry.queueDepth, lessThanOrEqualTo(3));
    expect(telemetry.queueBytes, lessThanOrEqualTo(700));
    expect(telemetry.stats['totalDropped'], greaterThan(0));
    final queued = telemetry.queueDepth;
    final dropped = telemetry.stats['totalDropped'];
    expect(
      () => telemetry.emit(
        kind: 'invalid.payload',
        payload: {'bad': _BadValue()},
      ),
      throwsArgumentError,
    );
    expect(telemetry.queueDepth, queued);
    expect(telemetry.stats['totalDropped'], dropped! + 1);
    await telemetry.stop();
  });

  test('limits every batch by event count and encoded bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <String>[];
    server.listen((request) async {
      bodies.add(await utf8.decoder.bind(request).join());
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    final cycle = <Object?>[];
    cycle.add(cycle);
    final telemetry = Telemetry(
      maxQueueBytes: 4000,
      maxEventBytes: 800,
      maxBatchEvents: 2,
      maxBatchBytes: 900,
      maxPayloadItems: 8,
      maxPayloadStringLength: 80,
      flushInterval: const Duration(hours: 1),
      captureLogs: false,
      captureLifecycle: false,
    );
    telemetry.start(
      collectorUrl: 'http://127.0.0.1:${server.port}',
      appId: 'app',
    );
    telemetry.emit(
      kind: 'safe',
      payload: {
        'nan': double.nan,
        'cycle': cycle,
        'uri': Uri.parse('https://example.com'),
      },
    );
    telemetry.emit(kind: 'third');
    telemetry.emit(kind: 'fourth');

    await telemetry.flushNow();
    await telemetry.flushNow();

    expect(bodies, hasLength(2));
    for (final body in bodies) {
      expect(utf8.encode(body).length, lessThanOrEqualTo(900));
      expect(
        (jsonDecode(body) as Map<String, dynamic>)['events'],
        hasLength(2),
      );
    }
    final firstEvents =
        (jsonDecode(bodies.first) as Map<String, dynamic>)['events']
            as List<dynamic>;
    final payload =
        (firstEvents.last as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    expect(payload['nan'], 'NaN');
    expect(payload['cycle'], ['[cycle]']);
    expect(payload['uri'], 'https://example.com');
    await telemetry.stop();
    await server.close(force: true);
  });

  test('offline failures do not enqueue telemetry logs', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    final telemetry = Telemetry(
      flushInterval: const Duration(hours: 1),
      connectTimeout: const Duration(milliseconds: 200),
      requestTimeout: const Duration(milliseconds: 200),
      captureLifecycle: false,
    );
    telemetry.start(collectorUrl: 'http://127.0.0.1:$port', appId: 'app');

    await telemetry.flushNow();

    expect(telemetry.queueDepth, 1);
    expect(telemetry.stats['totalFailed'], 1);
    await telemetry.stop();
  });

  test('logs are not captured unless requested explicitly', () async {
    final telemetry = Telemetry(
      flushInterval: const Duration(hours: 1),
      captureLifecycle: false,
    );
    telemetry.start(collectorUrl: 'http://localhost:1', appId: 'app');

    Logger('app').warning('private');

    await pumpEventQueue();
    expect(telemetry.queueDepth, 1);
    await telemetry.stop();
  });

  test('stop cancels an active request and prevents queue rerouting', () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    final release = Completer<void>();
    first.listen((request) async {
      await request.drain<void>();
      requestSeen.complete();
      await release.future;
      await request.response.close();
    });
    final telemetry = Telemetry(
      flushInterval: const Duration(hours: 1),
      requestTimeout: const Duration(seconds: 10),
      captureLogs: false,
      captureLifecycle: false,
    );
    telemetry.start(
      collectorUrl: 'http://127.0.0.1:${first.port}',
      appId: 'app',
    );
    telemetry.emit(kind: 'old.event');
    final flush = telemetry.flushNow();
    await requestSeen.future;

    await telemetry.stop().timeout(const Duration(seconds: 2));
    await flush;
    release.complete();
    expect(telemetry.queueDepth, 0);
    expect(() => telemetry.emit(kind: 'ignored'), throwsA(isA<StateError>()));
    expect(telemetry.queueDepth, 0);
    await first.close(force: true);

    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    second.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.complete(jsonDecode(body) as Map<String, dynamic>);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });
    telemetry.start(
      collectorUrl: 'http://127.0.0.1:${second.port}',
      appId: 'app',
    );
    await telemetry.flushNow();
    final events = (await received.future)['events'] as List<dynamic>;
    expect(events, hasLength(1));
    expect((events.single as Map<String, dynamic>)['kind'], 'telemetry_start');
    expect(events.toString(), isNot(contains('old.event')));
    await telemetry.stop();
    await second.close(force: true);
  });
}

class _BadValue extends Iterable<Object?> {
  @override
  Iterator<Object?> get iterator => throw StateError('cannot encode');
}
