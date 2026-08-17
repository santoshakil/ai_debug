import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_debug/ai_debug.dart';
import 'package:ai_debug/src/discovery/mdns.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  group('HTTP server', () {
    tearDown(() async {
      await AiDebug.dispose();
      AiDebug.clearRegisteredTools();
    });

    test('serves only exact routes', () async {
      await startServer();
      expect((await request('GET', '/healthz')).status, HttpStatus.ok);
      expect((await request('GET', '/mcp2')).status, HttpStatus.notFound);
      expect((await request('GET', '/mcp/path')).status, HttpStatus.notFound);
      final wrongMethod = await request('POST', '/api/tools');
      expect(wrongMethod.status, HttpStatus.methodNotAllowed);
      expect(wrongMethod.headers.value(HttpHeaders.allowHeader), 'GET');
    });

    test('serves a locked local dashboard', () async {
      await startServer();
      final response = await request('GET', '/dashboard', authenticate: false);
      expect(response.status, HttpStatus.ok);
      expect(response.body, contains('<title>ai_debug</title>'));
      expect(response.body, contains('devtools.resources.status'));
      expect(response.body, contains('devtools.frames.summary'));
      expect(response.body, contains('errors.status'));
      expect(response.body, contains('app.lifecycle'));
      expect(response.body, contains('state.sources'));
      expect(response.body, contains('network.status'));
      expect(response.body, contains('app.routes'));
      expect(response.body, contains('devtools.trace.status'));
      expect(response.body, contains('isolates.status'));
      expect(response.body, contains('data-ui="devtools.ui.semantics"'));
      expect(response.body, contains('data-ui="devtools.ui.layers"'));
      expect(response.body, contains('type="password"'));
      expect(response.body, contains("'authorization':'Bearer '+token"));
      expect(
        response.headers.value('content-security-policy'),
        contains("default-src 'none'"),
      );
    });

    test('lists tools in stable name order', () async {
      AiDebug.register(
        name: 'z_test',
        description: 'z',
        handler: (_) => const {'ok': true},
      );
      AiDebug.register(
        name: 'a_test',
        description: 'a',
        handler: (_) => const {'ok': true},
      );
      await startServer();
      final response = await request('GET', '/api/tools');
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final names = [
        for (final tool in body['tools'] as List)
          (tool as Map<String, dynamic>)['name'] as String,
      ];
      expect(names, orderedEquals([...names]..sort()));
    });

    test('paginates the direct tool inventory within the result cap', () async {
      for (var i = 0; i < 10; i++) {
        AiDebug.register(
          name: 'inventory_$i',
          description: 'x' * 300,
          handler: (_) => null,
        );
      }
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        maxResultBytes: 1024,
        features: const AiDebugFeatures.none(),
      );

      final first = await request('GET', '/api/tools?limit=500');
      final firstBody = jsonDecode(first.body) as Map<String, dynamic>;
      final cursor = firstBody['nextCursor'] as String;
      final second = await request(
        'GET',
        '/api/tools?limit=500&cursor=${Uri.encodeQueryComponent(cursor)}',
      );

      expect(first.status, HttpStatus.ok);
      expect(first.bytes.length, lessThanOrEqualTo(1024));
      expect(second.status, HttpStatus.ok);
      expect(second.bytes.length, lessThanOrEqualTo(1024));
    });

    test('caps the direct log response', () async {
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        maxResultBytes: 1024,
        features: const AiDebugFeatures(
          diagnostics: false,
          state: false,
          resources: false,
          isolates: false,
        ),
      );
      Logger('server-cap-test').info('x' * 5000);

      final response = await request('GET', '/api/logs?limit=10');

      expect(response.status, HttpStatus.requestEntityTooLarge);
      expect(response.body, contains('log result too large'));
    });

    test('rejects duplicate and reserved tool names', () {
      AiDebug.register(
        name: 'duplicate_test',
        description: 'first',
        handler: (_) => null,
      );
      expect(
        () => AiDebug.register(
          name: 'duplicate_test',
          description: 'second',
          handler: (_) => null,
        ),
        throwsStateError,
      );
      expect(
        () => AiDebug.register(
          name: 'tail_logs',
          description: 'reserved',
          handler: (_) => null,
        ),
        throwsArgumentError,
      );
    });

    test('enforces JSON content type and body limit', () async {
      AiDebug.register(
        name: 'body_test',
        description: 'body',
        handler: (args) => args,
      );
      await startServer();
      expect(
        (await request('POST', '/api/cmd/body_test', body: '{}')).status,
        HttpStatus.unsupportedMediaType,
      );
      await AiDebug.dispose();
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        maxBodyBytes: 8,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      final response = await request(
        'POST',
        '/api/cmd/body_test',
        body: '{"long":"value"}',
        contentType: ContentType.json,
      );
      expect(response.status, HttpStatus.requestEntityTooLarge);
    });

    test('validates built-in command arguments', () async {
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        features: const AiDebugFeatures.none(logs: true),
      );
      final cases = <(String, Map<String, Object?>, String)>[
        ('list_apps', {'extra': true}, r'$.extra is not allowed'),
        ('tail_logs', {'limit': '10'}, r'$.limit must be an integer'),
        ('tail_logs', {'extra': true}, r'$.extra is not allowed'),
        ('tail_logs', {'level': 'fatal'}, r'$.level must be one of'),
      ];

      for (final (name, args, error) in cases) {
        final response = await request(
          'POST',
          '/api/cmd/$name',
          body: jsonEncode(args),
          contentType: ContentType.json,
        );
        final body = jsonDecode(response.body) as Map<String, dynamic>;

        expect(response.status, HttpStatus.ok, reason: name);
        expect(body['success'], isFalse, reason: name);
        expect(body['error'], contains(error), reason: name);
      }
    });

    test('rejects a second start with different settings', () async {
      await startServer();
      await expectLater(
        AiDebug.start(
          appId: 'different',
          port: AiDebug.endpointPort!,
          features: const AiDebugFeatures(
            diagnostics: false,
            logs: false,
            state: false,
            resources: false,
          ),
        ),
        throwsStateError,
      );
    });

    test('accepts the same settings and keeps the endpoint', () async {
      await startServer();
      final host = AiDebug.endpointHost;
      final port = AiDebug.endpointPort;
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        features: const AiDebugFeatures.none(),
      );
      expect(AiDebug.endpointHost, host);
      expect(AiDebug.endpointPort, port);
    });

    test('stops and starts again cleanly', () async {
      await startServer();
      await AiDebug.dispose();
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      expect((await request('GET', '/healthz')).status, HttpStatus.ok);
      expect(AiDebug.endpointPort, isNotNull);
    });

    test('body timeout is absolute when no bytes arrive', () async {
      AiDebug.register(
        name: 'body_test',
        description: 'body',
        handler: (args) => args,
      );
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        bodyTimeout: const Duration(milliseconds: 80),
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      final socket = await Socket.connect(
        AiDebug.endpointHost!,
        AiDebug.endpointPort!,
      );
      addTearDown(socket.destroy);
      socket.write(
        'POST /api/cmd/body_test HTTP/1.1\r\n'
        'Host: ${AiDebug.endpointHost}:${AiDebug.endpointPort}\r\n'
        'Authorization: Bearer ${AiDebug.token}\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: 10\r\n'
        'Connection: close\r\n'
        '\r\n',
      );
      await socket.flush();
      final response = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 2));
      expect(response, startsWith('HTTP/1.1 408'));
    });

    test('limits tool results', () async {
      AiDebug.register(
        name: 'large_result',
        description: 'large result',
        handler: (_) => 'x' * 5000,
      );
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        maxResultBytes: 1024,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      final response = await request(
        'POST',
        '/api/cmd/large_result',
        body: '{}',
        contentType: ContentType.json,
      );
      expect(response.status, HttpStatus.requestEntityTooLarge);
    });

    test('bad handler error text returns a bounded fallback', () async {
      AiDebug.register(
        name: 'bad_error',
        description: 'bad error',
        handler: (_) => throw _BadText(),
      );
      await startServer();

      final response = await request(
        'POST',
        '/api/cmd/bad_error',
        body: '{}',
        contentType: ContentType.json,
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;

      expect(response.status, HttpStatus.ok);
      expect(body['success'], isFalse);
      expect(body['error'], '<unavailable>');
    });

    test('bounds the waiting tool queue', () async {
      final entered = Completer<void>();
      final release = Completer<Object?>();
      AiDebug.register(
        name: 'queued_tool',
        description: 'queued tool',
        handler: (_) {
          entered.complete();
          return release.future;
        },
      );
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        maxQueuedTools: 0,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      final first = request(
        'POST',
        '/api/cmd/queued_tool',
        body: '{}',
        contentType: ContentType.json,
      );
      await entered.future;
      final limited = await request(
        'POST',
        '/api/cmd/queued_tool',
        body: '{}',
        contentType: ContentType.json,
      );
      expect(limited.status, HttpStatus.tooManyRequests);
      release.complete(const {'ok': true});
      expect((await first).status, HttpStatus.ok);
    });

    test('timed out tools cannot overlap the next tool', () async {
      final entered = Completer<void>();
      final release = Completer<Object?>();
      var secondEntered = false;
      AiDebug.register(
        name: 'slow_tool',
        description: 'slow tool',
        handler: (_) {
          entered.complete();
          return release.future;
        },
      );
      AiDebug.register(
        name: 'next_tool',
        description: 'next tool',
        handler: (_) {
          secondEntered = true;
          return const {'ok': true};
        },
      );
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        toolTimeout: const Duration(milliseconds: 50),
        maxQueuedTools: 0,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      final first = request(
        'POST',
        '/api/cmd/slow_tool',
        body: '{}',
        contentType: ContentType.json,
      );
      await entered.future;
      expect((await first).status, HttpStatus.gatewayTimeout);
      final blocked = await request(
        'POST',
        '/api/cmd/next_tool',
        body: '{}',
        contentType: ContentType.json,
      );
      expect(blocked.status, HttpStatus.tooManyRequests);
      expect(secondEntered, isFalse);
      release.complete(const {'ok': true});
      await pumpEventQueue();
      final next = await request(
        'POST',
        '/api/cmd/next_tool',
        body: '{}',
        contentType: ContentType.json,
      );
      expect(next.status, HttpStatus.ok);
      expect(secondEntered, isTrue);
    });

    test('dispose waits for a timed out tool handler to finish', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var finished = false;
      AiDebug.register(
        name: 'dispose_tool',
        description: 'dispose tool',
        handler: (_) async {
          entered.complete();
          await release.future;
          finished = true;
          return const {'ok': true};
        },
      );
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        toolTimeout: const Duration(milliseconds: 20),
        features: const AiDebugFeatures.none(),
      );
      final call = request(
        'POST',
        '/api/cmd/dispose_tool',
        body: '{}',
        contentType: ContentType.json,
      );
      await entered.future;
      expect((await call).status, HttpStatus.gatewayTimeout);

      var disposed = false;
      final dispose = AiDebug.dispose().then((_) => disposed = true);
      await pumpEventQueue();
      expect(disposed, isFalse);
      expect(finished, isFalse);

      release.complete();
      await dispose;
      expect(disposed, isTrue);
      expect(finished, isTrue);
    });

    test('caps file reads and permits bounded ranges', () async {
      final dir = await Directory.systemTemp.createTemp('ai-debug-file-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/large.bin');
      await file.writeAsBytes(List<int>.generate(2048, (i) => i % 256));
      await AiDebug.start(
        appId: 'server-test',
        port: 0,
        maxResultBytes: 1024,
        allowedFileRoots: {dir.path},
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
          files: true,
          isolates: false,
        ),
      );
      final path = '/api/file?path=${Uri.encodeQueryComponent(file.path)}';

      final full = await request('GET', path);
      final range = await request(
        'GET',
        path,
        headers: {HttpHeaders.rangeHeader: 'bytes=16-47'},
      );
      final largeRange = await request(
        'GET',
        path,
        headers: {HttpHeaders.rangeHeader: 'bytes=0-1500'},
      );

      expect(full.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(range.status, HttpStatus.partialContent);
      expect(range.bytes, List<int>.generate(32, (i) => i + 16));
      expect(range.headers.value('cache-control'), 'no-store');
      expect(largeRange.status, HttpStatus.requestedRangeNotSatisfiable);
    });
  });

  group('security', () {
    tearDown(() async {
      await AiDebug.dispose();
      AiDebug.clearRegisteredTools();
    });

    test('requires auth and rejects query tokens', () async {
      await AiDebug.start(
        appId: 'auth-test',
        port: 0,
        token: 'secret',
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      expect((await request('GET', '/healthz')).status, HttpStatus.ok);
      expect(
        (await request('GET', '/api/tools', authenticate: false)).status,
        HttpStatus.unauthorized,
      );
      expect(
        (await request(
          'GET',
          '/api/tools?token=secret',
          authenticate: false,
        )).status,
        HttpStatus.unauthorized,
      );
      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'authorization': 'Bearer secret'},
        )).status,
        HttpStatus.ok,
      );
    });

    test('allows only configured browser origins', () async {
      await AiDebug.start(
        appId: 'cors-test',
        port: 0,
        allowedOrigins: {'https://debug.example'},
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      final denied = await request(
        'GET',
        '/api/tools',
        headers: {'origin': 'https://evil.example'},
      );
      expect(denied.status, HttpStatus.forbidden);
      final allowed = await request(
        'GET',
        '/api/tools',
        headers: {'origin': 'https://debug.example'},
      );
      expect(allowed.status, HttpStatus.ok);
      expect(
        allowed.headers.value('access-control-allow-origin'),
        'https://debug.example',
      );
    });

    test('allows the dashboard same origin', () async {
      await AiDebug.start(
        appId: 'same-origin-test',
        port: 0,
        features: const AiDebugFeatures.none(),
      );
      final authority = '${AiDebug.endpointHost}:${AiDebug.endpointPort}';
      final response = await request(
        'POST',
        '/api/cmd/list_apps',
        body: '{}',
        contentType: ContentType.json,
        headers: {'origin': 'http://$authority', 'host': authority},
      );

      expect(response.status, HttpStatus.ok);
      expect(
        response.headers.value('access-control-allow-origin'),
        'http://$authority',
      );
    });

    test('rejects unlisted hosts', () async {
      await AiDebug.start(
        appId: 'host-test',
        port: 0,
        allowedHosts: {'debug.local'},
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
        ),
      );
      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'host': 'evil.example'},
        )).status,
        HttpStatus.forbidden,
      );
      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'host': 'debug.local'},
        )).status,
        HttpStatus.ok,
      );
      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'host': 'debug.local:${AiDebug.endpointPort}'},
        )).status,
        HttpStatus.ok,
      );
      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'host': 'debug.local:1'},
        )).status,
        HttpStatus.forbidden,
      );
    });

    test('keeps configured host ports exact', () async {
      await AiDebug.start(
        appId: 'host-test',
        port: 0,
        allowedHosts: {'debug.local:4242'},
        features: const AiDebugFeatures.none(),
      );

      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'host': 'debug.local:4242'},
        )).status,
        HttpStatus.ok,
      );
      expect(
        (await request(
          'GET',
          '/api/tools',
          headers: {'host': 'debug.local'},
        )).status,
        HttpStatus.forbidden,
      );
    });

    test('rejects malformed allowed host authorities', () async {
      await expectLater(
        AiDebug.start(
          appId: 'host-test',
          port: 0,
          allowedHosts: {'debug.local/path'},
          features: const AiDebugFeatures.none(),
        ),
        throwsArgumentError,
      );
    });

    test('accepts its advertised mDNS hostname', () async {
      await AiDebug.start(
        appId: 'host-test',
        port: 0,
        features: const AiDebugFeatures.none(),
      );
      final host = mdnsHostname('host-test');

      final response = await request(
        'GET',
        '/api/tools',
        headers: {'host': '$host:${AiDebug.endpointPort}'},
      );

      expect(response.status, HttpStatus.ok);
    });

    test('does not expose plain HTTP outside loopback by default', () async {
      await expectLater(
        AiDebug.start(
          appId: 'lan-test',
          bindHost: '0.0.0.0',
          port: 0,
          token: 'secret',
          features: const AiDebugFeatures(
            diagnostics: false,
            logs: false,
            state: false,
            resources: false,
          ),
        ),
        throwsStateError,
      );
    });

    test('requires a strong token outside loopback', () async {
      await expectLater(
        AiDebug.start(
          appId: 'lan-test',
          bindHost: '0.0.0.0',
          port: 0,
          token: 'short',
          unsafeLan: true,
          features: const AiDebugFeatures.none(),
        ),
        throwsArgumentError,
      );
    });
  });
}

Future<void> startServer() => AiDebug.start(
  appId: 'server-test',
  port: 0,
  features: const AiDebugFeatures.none(),
);

class TestResponse {
  TestResponse(this.status, this.headers, this.bytes);

  final int status;
  final HttpHeaders headers;
  final List<int> bytes;

  String get body => utf8.decode(bytes);
}

Future<TestResponse> request(
  String method,
  String path, {
  String? body,
  ContentType? contentType,
  Map<String, String> headers = const {},
  bool authenticate = true,
}) async {
  final client = HttpClient();
  try {
    final request = await client.open(
      method,
      AiDebug.endpointHost!,
      AiDebug.endpointPort!,
      path,
    );
    if (contentType != null) request.headers.contentType = contentType;
    if (authenticate &&
        !headers.keys.any((key) => key.toLowerCase() == 'authorization')) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${AiDebug.token}',
      );
    }
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    return TestResponse(response.statusCode, response.headers, bytes);
  } finally {
    client.close(force: true);
  }
}

class _BadText {
  @override
  String toString() => throw StateError('no text');
}
