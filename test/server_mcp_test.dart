import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_debug/ai_debug.dart';
import 'package:flutter_test/flutter_test.dart';

import 'server_smoke_test.dart' show TestResponse, request;

void main() {
  tearDown(() async {
    await AiDebug.dispose();
    AiDebug.clearRegisteredTools();
  });

  test('requires Streamable HTTP content negotiation', () async {
    await startMcp();
    final response = await mcpRequest({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'ping',
    }, accept: 'application/json');
    expect(response.status, HttpStatus.notAcceptable);
    final invalid = await mcpRequest({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'ping',
    }, accept: 'application/jsonx, text/event-stream');
    expect(invalid.status, HttpStatus.notAcceptable);
  });

  test('negotiates and enforces session lifecycle', () async {
    await startMcp();
    final initialized = await initialize('2025-11-25');
    expect(initialized.response.status, HttpStatus.ok);
    expect(initialized.session, isNotEmpty);
    expect(
      (jsonDecode(initialized.response.body)
          as Map<String, dynamic>)['result']['protocolVersion'],
      '2025-11-25',
    );

    final tooEarly = await mcpRequest(
      {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(
      ((jsonDecode(tooEarly.body) as Map<String, dynamic>)['error']
          as Map<String, dynamic>)['code'],
      -32600,
    );

    final ready = await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(ready.status, HttpStatus.accepted);

    final tools = await mcpRequest(
      {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(tools.status, HttpStatus.ok);
    expect(
      (jsonDecode(tools.body) as Map<String, dynamic>)['result'],
      isA<Map<String, dynamic>>(),
    );
  });

  test('selects latest version for an unknown client version', () async {
    await startMcp();
    final initialized = await initialize('2099-01-01');
    final body = jsonDecode(initialized.response.body) as Map<String, dynamic>;
    expect(
      (body['result'] as Map<String, dynamic>)['protocolVersion'],
      '2025-11-25',
    );
  });

  test('accepts client notifications and responses with no body', () async {
    await startMcp();
    final initialized = await initialize('2025-11-25');
    final notification = await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(notification.status, HttpStatus.accepted);
    expect(notification.bytes, isEmpty);

    final result = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'id': 10,
        'result': {'ok': true},
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(result.status, HttpStatus.accepted);
    expect(result.bytes, isEmpty);

    final error = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'id': 'server-call',
        'error': {'code': -32601, 'message': 'not supported'},
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(error.status, HttpStatus.accepted);
    expect(error.bytes, isEmpty);
  });

  test('requires initialize first and rejects duplicate initialize', () async {
    await startMcp();
    final beforeInitialize = await mcpRequest({
      'jsonrpc': '2.0',
      'id': 1,
      'result': {'ok': true},
    });
    expect(beforeInitialize.status, HttpStatus.badRequest);
    expect(beforeInitialize.headers.value('mcp-session-id'), isNull);

    final initialized = await initialize('2025-11-25');
    final duplicate = await mcpRequest(
      initializeMessage('2025-11-25'),
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(duplicate.status, HttpStatus.badRequest);
    expect(duplicate.headers.value('mcp-session-id'), isNull);
  });

  test(
    'uses the legacy header fallback only for its matching session',
    () async {
      await startMcp();
      final legacy = await initialize('2025-03-26');
      final accepted = await mcpRequest({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, session: legacy.session);
      expect(accepted.status, HttpStatus.accepted);

      final latest = await initialize('2025-11-25');
      final rejected = await mcpRequest({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, session: latest.session);
      expect(rejected.status, HttpStatus.badRequest);
    },
  );

  test('rejects missing, wrong, and deleted sessions', () async {
    await startMcp();
    final initialized = await initialize('2025-06-18');
    final missing = await mcpRequest({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'ping',
    });
    expect(missing.status, HttpStatus.badRequest);

    final wrongVersion = await mcpRequest(
      {'jsonrpc': '2.0', 'id': 3, 'method': 'ping'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    expect(wrongVersion.status, HttpStatus.badRequest);

    final deleted = await request(
      'DELETE',
      '/mcp',
      headers: {
        'mcp-session-id': initialized.session,
        'mcp-protocol-version': '2025-06-18',
      },
    );
    expect(deleted.status, HttpStatus.accepted);
    final afterDelete = await mcpRequest(
      {'jsonrpc': '2.0', 'id': 4, 'method': 'ping'},
      session: initialized.session,
      protocol: '2025-06-18',
    );
    expect(afterDelete.status, HttpStatus.notFound);
  });

  test('calls a tool and reports handler failures as tool results', () async {
    AiDebug.register(
      name: 'mcp_echo',
      description: 'echo',
      inputSchema: AiDebugSchema.object(
        {'value': AiDebugSchema.string()},
        required: ['value'],
      ),
      handler: (args) => {'value': args['value']},
    );
    AiDebug.register(
      name: 'mcp_fail',
      description: 'fail',
      handler: (_) => throw StateError('expected failure'),
    );
    await startMcp();
    final initialized = await initialize('2025-11-25');
    await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );

    final echoed = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'mcp_echo',
          'arguments': {'value': 'yes'},
        },
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );
    final result =
        (jsonDecode(echoed.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    expect(result['structuredContent'], {'value': 'yes'});

    final failed = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'mcp_fail'},
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );
    final failedResult =
        (jsonDecode(failed.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    expect(failedResult['isError'], isTrue);
  });

  test('validates built-in tool arguments', () async {
    await startMcp(logs: true);
    final initialized = await initialize('2025-11-25');
    await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    final cases = <(String, Map<String, Object?>, String)>[
      ('list_apps', {'extra': true}, r'$.extra is not allowed'),
      ('tail_logs', {'limit': '10'}, r'$.limit must be an integer'),
      ('tail_logs', {'extra': true}, r'$.extra is not allowed'),
      ('tail_logs', {'level': 'fatal'}, r'$.level must be one of'),
    ];

    for (var i = 0; i < cases.length; i++) {
      final (name, args, error) = cases[i];
      final response = await mcpRequest(
        {
          'jsonrpc': '2.0',
          'id': i + 2,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': args},
        },
        session: initialized.session,
        protocol: '2025-11-25',
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final rpcError = body['error'] as Map<String, dynamic>;

      expect(rpcError['code'], -32602, reason: name);
      expect(rpcError['message'], contains(error), reason: name);
    }
  });

  test('rejects null ids and batches', () async {
    await startMcp();
    final nullId = await mcpRequest({
      'jsonrpc': '2.0',
      'id': null,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'test', 'version': '1'},
      },
    });
    expect(nullId.status, HttpStatus.badRequest);
    final batch = await mcpRequest([
      {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    ]);
    expect(batch.status, HttpStatus.badRequest);
  });

  test('accepts finite numeric ids and cancellation notifications', () async {
    await startMcp();
    final initialized = await initialize('2025-11-25');
    await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );

    final ping = await mcpRequest(
      {'jsonrpc': '2.0', 'id': 1.5, 'method': 'ping'},
      session: initialized.session,
      protocol: '2025-11-25',
    );
    final cancelled = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'method': 'notifications/cancelled',
        'params': {'requestId': 1.5, 'reason': 'client stopped'},
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );

    expect((jsonDecode(ping.body) as Map<String, dynamic>)['id'], 1.5);
    expect(cancelled.status, HttpStatus.accepted);
  });

  test('rejects initialize without client name and version strings', () async {
    await startMcp();

    final response = await mcpRequest({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 1, 'version': null},
      },
    });
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(response.status, HttpStatus.badRequest);
    expect((body['error'] as Map<String, dynamic>)['code'], -32602);
  });

  test('paginates MCP tool inventory within the result cap', () async {
    for (var i = 0; i < 10; i++) {
      AiDebug.register(
        name: 'inventory_$i',
        description: 'x' * 300,
        handler: (_) => null,
      );
    }
    await startMcp(maxResultBytes: 1024);
    final initialized = await initialize('2025-11-25');
    await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );

    String? cursor;
    final names = <String>[];
    var id = 2;
    do {
      final response = await mcpRequest(
        {
          'jsonrpc': '2.0',
          'id': id++,
          'method': 'tools/list',
          if (cursor != null) 'params': {'cursor': cursor},
        },
        session: initialized.session,
        protocol: '2025-11-25',
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final result = body['result'] as Map<String, dynamic>;
      names.addAll([
        for (final tool in result['tools'] as List)
          (tool as Map<String, dynamic>)['name'] as String,
      ]);
      cursor = result['nextCursor'] as String?;
      expect(response.bytes.length, lessThanOrEqualTo(1024));
    } while (cursor != null);

    expect(names, containsAll([for (var i = 0; i < 10; i++) 'inventory_$i']));
  });

  test('returns bounded non-image binary resources', () async {
    AiDebug.register(
      name: 'binary_resource',
      description: 'binary resource',
      handler: (_) => AiDebugResult.binary(
        Uint8List.fromList([1, 2, 3, 4]),
        mime: 'application/pdf',
      ),
    );
    await startMcp(maxResultBytes: 2048);
    final initialized = await initialize('2025-11-25');
    await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );

    final response = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'binary_resource'},
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );
    final result =
        (jsonDecode(response.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    final content = (result['content'] as List).single as Map<String, dynamic>;
    final resource = content['resource'] as Map<String, dynamic>;

    expect(content['type'], 'resource');
    expect(resource['mimeType'], 'application/pdf');
    expect(base64Decode(resource['blob'] as String), [1, 2, 3, 4]);
    expect(response.bytes.length, lessThanOrEqualTo(2048));
  });

  test('rejects oversized non-image binary results before encoding', () async {
    AiDebug.register(
      name: 'large_binary',
      description: 'large binary',
      handler: (_) => AiDebugResult.binary(
        Uint8List(2000),
        mime: 'application/octet-stream',
      ),
    );
    await startMcp(maxResultBytes: 1024);
    final initialized = await initialize('2025-11-25');
    await mcpRequest(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: initialized.session,
      protocol: '2025-11-25',
    );

    final response = await mcpRequest(
      {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'large_binary'},
      },
      session: initialized.session,
      protocol: '2025-11-25',
    );
    final result =
        (jsonDecode(response.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;

    expect(result['isError'], isTrue);
    expect(response.body, contains('tool result too large'));
  });

  test('serves stateless 2026 discovery and ping', () async {
    await startMcp();

    final discovered = await modernRequest(
      modernMessage(1, 'server/discover'),
      session: 'ignored-session',
    );
    final discoverResult =
        (jsonDecode(discovered.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    final info =
        (discoverResult['_meta']
                as Map<String, dynamic>)['io.modelcontextprotocol/serverInfo']
            as Map<String, dynamic>;

    expect(discovered.status, HttpStatus.ok);
    expect(discovered.headers.value('mcp-session-id'), isNull);
    expect(discoverResult['resultType'], 'complete');
    expect(discoverResult['supportedVersions'], ['2026-07-28']);
    expect(discoverResult['capabilities'], {
      'tools': {'listChanged': false},
    });
    expect(discoverResult['ttlMs'], 300000);
    expect(discoverResult['cacheScope'], 'private');
    expect(info['name'], 'ai_debug');
    expect(info['version'], isNotEmpty);

    final pingMessage = modernMessage(2, 'ping');
    ((pingMessage['params'] as Map<String, Object?>)['_meta']
            as Map<String, Object?>)
        .remove('io.modelcontextprotocol/clientInfo');
    final ping = await modernRequest(pingMessage);
    final pingResult =
        (jsonDecode(ping.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    expect(ping.status, HttpStatus.ok);
    expect(pingResult['resultType'], 'complete');
    expect(pingResult['_meta'], isA<Map<String, dynamic>>());
  });

  test('lists and calls tools with stateless 2026 requests', () async {
    AiDebug.register(
      name: 'modern_echo',
      description: 'echo',
      handler: (_) => const ['yes', 2],
    );
    await startMcp();

    final listed = await modernRequest(modernMessage(1, 'tools/list'));
    final listResult =
        (jsonDecode(listed.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    final names = [
      for (final tool in listResult['tools'] as List)
        (tool as Map<String, dynamic>)['name'],
    ];
    expect(names, contains('modern_echo'));
    expect(listResult['resultType'], 'complete');
    expect(listResult['ttlMs'], 300000);
    expect(listResult['cacheScope'], 'private');
    expect(listResult['_meta'], isA<Map<String, dynamic>>());

    final called = await modernRequest(
      modernMessage(
        2,
        'tools/call',
        params: {'name': 'modern_echo', 'arguments': <String, Object?>{}},
      ),
      name: '=?base64?${base64Encode(utf8.encode('modern_echo'))}?=',
    );
    final callResult =
        (jsonDecode(called.body) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    expect(called.status, HttpStatus.ok);
    expect(callResult['resultType'], 'complete');
    expect(callResult['structuredContent'], ['yes', 2]);
    expect(callResult['isError'], isFalse);
    expect(callResult['_meta'], isA<Map<String, dynamic>>());
  });

  test('rejects invalid 2026 metadata and transport headers', () async {
    await startMcp();
    final missingCapabilities = modernMessage(1, 'tools/list');
    ((missingCapabilities['params'] as Map<String, Object?>)['_meta']
            as Map<String, Object?>)
        .remove('io.modelcontextprotocol/clientCapabilities');

    final cases = <(Future<TestResponse>, int)>[
      (modernRequest(missingCapabilities), -32602),
      (
        modernRequest(modernMessage(2, 'tools/list'), includeProtocol: false),
        -32020,
      ),
      (
        modernRequest(modernMessage(3, 'tools/list'), method: 'tools/call'),
        -32020,
      ),
      (
        modernRequest(modernMessage(31, 'tools/list'), includeMethod: false),
        -32020,
      ),
      (
        modernRequest(modernMessage(32, 'tools/list'), protocol: '2025-11-25'),
        -32020,
      ),
      (
        modernRequest(
          modernMessage(4, 'tools/call', params: {'name': 'list_apps'}),
          includeName: false,
        ),
        -32020,
      ),
      (
        modernRequest(
          modernMessage(5, 'tools/call', params: {'name': 'list_apps'}),
          name: 'wrong',
        ),
        -32020,
      ),
    ];

    for (final (future, code) in cases) {
      final response = await future;
      final error =
          (jsonDecode(response.body) as Map<String, dynamic>)['error']
              as Map<String, dynamic>;
      expect(response.status, HttpStatus.badRequest);
      expect(error['code'], code);
    }
  });

  test('paginates the 2026 tool list within the result cap', () async {
    for (var i = 0; i < 10; i++) {
      AiDebug.register(
        name: 'modern_inventory_$i',
        description: 'x' * 300,
        handler: (_) => null,
      );
    }
    await startMcp(maxResultBytes: 1024);

    String? cursor;
    final names = <String>[];
    var id = 1;
    do {
      final response = await modernRequest(
        modernMessage(id++, 'tools/list', params: {'cursor': ?cursor}),
      );
      final result =
          (jsonDecode(response.body) as Map<String, dynamic>)['result']
              as Map<String, dynamic>;
      names.addAll([
        for (final tool in result['tools'] as List)
          (tool as Map<String, dynamic>)['name'] as String,
      ]);
      cursor = result['nextCursor'] as String?;
      expect(response.bytes.length, lessThanOrEqualTo(1024));
      expect(result['resultType'], 'complete');
      expect(result['ttlMs'], 300000);
      expect(result['cacheScope'], 'private');
    } while (cursor != null);

    expect(
      names,
      containsAll([for (var i = 0; i < 10; i++) 'modern_inventory_$i']),
    );
  });

  test('reports unsupported 2026-era versions and unknown methods', () async {
    await startMcp();
    final unsupported = await modernRequest(
      modernMessage(1, 'tools/list', version: '2099-01-01'),
      protocol: '2099-01-01',
    );
    final unsupportedError =
        (jsonDecode(unsupported.body) as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    final data = unsupportedError['data'] as Map<String, dynamic>;
    expect(unsupported.status, HttpStatus.badRequest);
    expect(unsupportedError['code'], -32022);
    expect(data['requested'], '2099-01-01');
    expect(data['supported'], contains('2026-07-28'));

    final unknown = await modernRequest(modernMessage(2, 'unknown/method'));
    final unknownError =
        (jsonDecode(unknown.body) as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(unknown.status, HttpStatus.notFound);
    expect(unknownError['code'], -32601);

    final fractional = await modernRequest(modernMessage(1.5, 'tools/list'));
    expect(fractional.status, HttpStatus.badRequest);
  });
}

Future<void> startMcp({
  int maxResultBytes = 4 * 1024 * 1024,
  bool logs = false,
}) => AiDebug.start(
  appId: 'mcp-test',
  port: 0,
  maxResultBytes: maxResultBytes,
  features: AiDebugFeatures.none(logs: logs),
);

Future<({TestResponse response, String session})> initialize(
  String version,
) async {
  final response = await mcpRequest(initializeMessage(version));
  return (
    response: response,
    session: response.headers.value('mcp-session-id') ?? '',
  );
}

Map<String, Object?> initializeMessage(String version) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'initialize',
  'params': {
    'protocolVersion': version,
    'capabilities': <String, Object?>{},
    'clientInfo': {'name': 'test', 'version': '1'},
  },
};

Map<String, Object?> modernMessage(
  Object id,
  String method, {
  Map<String, Object?> params = const {},
  String version = '2026-07-28',
}) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': {
    ...params,
    '_meta': {
      'io.modelcontextprotocol/protocolVersion': version,
      'io.modelcontextprotocol/clientInfo': {'name': 'test', 'version': '1'},
      'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
    },
  },
};

Future<TestResponse> modernRequest(
  Map<String, Object?> body, {
  String protocol = '2026-07-28',
  String? method,
  String? name,
  String? session,
  bool includeProtocol = true,
  bool includeMethod = true,
  bool includeName = true,
}) {
  final bodyMethod = body['method'] as String?;
  final params = body['params'] as Map<String, Object?>?;
  final bodyName = params?['name'] as String?;
  return request(
    'POST',
    '/mcp',
    body: jsonEncode(body),
    contentType: ContentType.json,
    headers: {
      'accept': 'application/json, text/event-stream',
      if (includeProtocol) 'mcp-protocol-version': protocol,
      if (includeMethod) 'mcp-method': method ?? bodyMethod!,
      if (includeName && bodyMethod == 'tools/call')
        'mcp-name': name ?? bodyName!,
      'mcp-session-id': ?session,
    },
  );
}

Future<TestResponse> mcpRequest(
  Object body, {
  String accept = 'application/json, text/event-stream',
  String? session,
  String? protocol,
}) => request(
  'POST',
  '/mcp',
  body: jsonEncode(body),
  contentType: ContentType.json,
  headers: {
    'accept': accept,
    'mcp-session-id': ?session,
    'mcp-protocol-version': ?protocol,
  },
);
