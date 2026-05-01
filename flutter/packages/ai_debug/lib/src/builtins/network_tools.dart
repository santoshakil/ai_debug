import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../registry.dart';

/// Network probes: local interfaces, URL latency, DNS resolution, TCP port checks.
void registerNetworkTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'network_self_ips',
    description:
        'List local network interface IPs (IPv4+IPv6). Useful to confirm wifi/cellular path '
        'and to know what address the device is reachable at on its LAN.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final list = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
        type: InternetAddressType.any,
      );
      return {
        'count': list.length,
        'interfaces': list
            .map((nif) => {
                  'name': nif.name,
                  'index': nif.index,
                  'addresses': nif.addresses
                      .map((a) => {
                            'address': a.address,
                            'host': a.host,
                            'isLoopback': a.isLoopback,
                            'isLinkLocal': a.isLinkLocal,
                            'isMulticast': a.isMulticast,
                            'rawAddress': a.rawAddress.toList(),
                            'type': a.type.name,
                          })
                      .toList(),
                })
            .toList(),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'network_probe_url',
    description:
        'HTTP HEAD/GET probe of a URL. Returns ok, status, latencyMs, contentLength, '
        'redirectChain, and error if failed. Default method=HEAD, timeout=5000ms.',
    inputSchema: AiDebugSchema.object(
      {
        'url': AiDebugSchema.string(description: 'http(s) URL'),
        'method': AiDebugSchema.string(default_: 'HEAD', enum_: ['HEAD', 'GET']),
        'timeoutMs': AiDebugSchema.integer(default_: 5000, min: 100, max: 60000),
      },
      required: ['url'],
    ),
    handler: (args) async {
      final url = args['url'] as String;
      final method = (args['method'] as String?) ?? 'HEAD';
      final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 5000;
      final sw = Stopwatch()..start();
      HttpClient? client;
      try {
        client = HttpClient()
          ..connectionTimeout = Duration(milliseconds: timeoutMs)
          ..userAgent = 'ai_debug/network_probe_url';
        final uri = Uri.parse(url);
        final HttpClientRequest req;
        switch (method) {
          case 'GET':
            req = await client.getUrl(uri).timeout(Duration(milliseconds: timeoutMs));
            break;
          case 'HEAD':
          default:
            req = await client.headUrl(uri).timeout(Duration(milliseconds: timeoutMs));
            break;
        }
        final res = await req.close().timeout(Duration(milliseconds: timeoutMs));
        sw.stop();
        final body = method == 'GET'
            ? await res.transform(const _Utf8Lossy()).join().timeout(Duration(milliseconds: timeoutMs))
            : null;
        return {
          'ok': res.statusCode < 400,
          'status': res.statusCode,
          'reason': res.reasonPhrase,
          'latencyMs': sw.elapsedMilliseconds,
          'contentLength': res.contentLength,
          'headers': _flattenHeaders(res.headers),
          if (body != null) 'body': body.length > 4096 ? body.substring(0, 4096) : body,
          if (body != null) 'bodyLength': body.length,
        };
      } on TimeoutException catch (e) {
        sw.stop();
        return {
          'ok': false,
          'error': 'timeout',
          'latencyMs': sw.elapsedMilliseconds,
          'detail': e.toString(),
        };
      } on SocketException catch (e) {
        sw.stop();
        return {
          'ok': false,
          'error': 'socket',
          'osError': e.osError?.toString(),
          'message': e.message,
          'address': e.address?.address,
          'port': e.port,
          'latencyMs': sw.elapsedMilliseconds,
        };
      } catch (e) {
        sw.stop();
        return {
          'ok': false,
          'error': 'other',
          'detail': e.toString(),
          'latencyMs': sw.elapsedMilliseconds,
        };
      } finally {
        client?.close(force: true);
      }
    },
  ));

  registry.add(ToolEntry(
    name: 'network_resolve',
    description: 'DNS resolve a hostname. Returns InternetAddress list + lookup ms.',
    inputSchema: AiDebugSchema.object(
      {
        'host': AiDebugSchema.string(),
        'timeoutMs': AiDebugSchema.integer(default_: 5000, min: 100, max: 30000),
      },
      required: ['host'],
    ),
    handler: (args) async {
      final host = args['host'] as String;
      final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 5000;
      final sw = Stopwatch()..start();
      try {
        final addrs = await InternetAddress.lookup(host).timeout(Duration(milliseconds: timeoutMs));
        sw.stop();
        return {
          'ok': true,
          'lookupMs': sw.elapsedMilliseconds,
          'count': addrs.length,
          'addresses': addrs
              .map((a) => {
                    'address': a.address,
                    'host': a.host,
                    'type': a.type.name,
                  })
              .toList(),
        };
      } on TimeoutException {
        sw.stop();
        return {'ok': false, 'error': 'timeout', 'lookupMs': sw.elapsedMilliseconds};
      } catch (e) {
        sw.stop();
        return {'ok': false, 'error': e.toString(), 'lookupMs': sw.elapsedMilliseconds};
      }
    },
  ));

  registry.add(ToolEntry(
    name: 'network_check_port',
    description:
        'TCP port reachability test. Opens a socket then closes it. Returns ok=true if connect succeeds.',
    inputSchema: AiDebugSchema.object(
      {
        'host': AiDebugSchema.string(),
        'port': AiDebugSchema.integer(min: 1, max: 65535),
        'timeoutMs': AiDebugSchema.integer(default_: 3000, min: 100, max: 30000),
      },
      required: ['host', 'port'],
    ),
    handler: (args) async {
      final host = args['host'] as String;
      final port = (args['port'] as num).toInt();
      final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 3000;
      final sw = Stopwatch()..start();
      try {
        final sock = await Socket.connect(
          host,
          port,
          timeout: Duration(milliseconds: timeoutMs),
        );
        sw.stop();
        final remote = sock.remoteAddress.address;
        sock.destroy();
        return {
          'ok': true,
          'connectMs': sw.elapsedMilliseconds,
          'remoteAddress': remote,
        };
      } on TimeoutException {
        sw.stop();
        return {'ok': false, 'error': 'timeout', 'connectMs': sw.elapsedMilliseconds};
      } on SocketException catch (e) {
        sw.stop();
        return {
          'ok': false,
          'error': 'socket',
          'osError': e.osError?.message,
          'message': e.message,
          'connectMs': sw.elapsedMilliseconds,
        };
      } catch (e) {
        sw.stop();
        return {'ok': false, 'error': e.toString(), 'connectMs': sw.elapsedMilliseconds};
      }
    },
  ));

  registry.add(ToolEntry(
    name: 'network_internet_ok',
    description:
        'Quick connectivity health check — probes 3 well-known endpoints (8.8.8.8:53, '
        '1.1.1.1:53, captive.apple.com:80). Returns reachable bools per endpoint and overall ok.',
    inputSchema: AiDebugSchema.object({
      'timeoutMs': AiDebugSchema.integer(default_: 2500, min: 100, max: 15000),
    }),
    handler: (args) async {
      final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 2500;
      Future<bool> check(String h, int p) async {
        try {
          final s = await Socket.connect(h, p, timeout: Duration(milliseconds: timeoutMs));
          s.destroy();
          return true;
        } catch (_) {
          return false;
        }
      }

      final results = await Future.wait<bool>([
        check('8.8.8.8', 53),
        check('1.1.1.1', 53),
        check('captive.apple.com', 80),
      ]);
      return {
        'google_dns': results[0],
        'cloudflare_dns': results[1],
        'apple_captive': results[2],
        'ok': results.any((r) => r),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'network_http_post_json',
    description:
        'POST a JSON body to a URL. Returns status, latency, response body. Useful to drive '
        'arbitrary HTTP endpoints from inside the app (e.g., to test a backend service directly).',
    inputSchema: AiDebugSchema.object(
      {
        'url': AiDebugSchema.string(),
        'body': AiDebugSchema.object({}),
        'headers': AiDebugSchema.object({}),
        'timeoutMs': AiDebugSchema.integer(default_: 10000, min: 100, max: 60000),
      },
      required: ['url'],
    ),
    handler: (args) async {
      final url = args['url'] as String;
      final body = args['body'];
      final headers = (args['headers'] as Map?)?.cast<String, dynamic>();
      final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 10000;
      final sw = Stopwatch()..start();
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = Duration(milliseconds: timeoutMs);
        final req = await client.postUrl(Uri.parse(url)).timeout(Duration(milliseconds: timeoutMs));
        req.headers.contentType = ContentType.json;
        if (headers != null) {
          for (final e in headers.entries) {
            req.headers.set(e.key, e.value.toString());
          }
        }
        var sentBytes = 0;
        if (body != null) {
          final jsonStr = jsonEncode(body);
          final bytes = utf8.encode(jsonStr);
          sentBytes = bytes.length;
          req.contentLength = bytes.length;
          req.bufferOutput = true;
          req.write(jsonStr);
        }
        final res = await req.close().timeout(Duration(milliseconds: timeoutMs));
        sw.stop();
        final text = await res.transform(const _Utf8Lossy()).join().timeout(Duration(milliseconds: timeoutMs));
        return {
          'ok': res.statusCode < 400,
          'status': res.statusCode,
          'latencyMs': sw.elapsedMilliseconds,
          'sentBytes': sentBytes,
          'body': text.length > 8192 ? text.substring(0, 8192) : text,
          'bodyLength': text.length,
        };
      } catch (e) {
        sw.stop();
        return {'ok': false, 'error': e.toString(), 'latencyMs': sw.elapsedMilliseconds};
      } finally {
        client?.close(force: true);
      }
    },
  ));
}

Map<String, List<String>> _flattenHeaders(HttpHeaders h) {
  final out = <String, List<String>>{};
  h.forEach((k, v) => out[k] = List<String>.from(v));
  return out;
}

class _Utf8Lossy extends StreamTransformerBase<List<int>, String> {
  const _Utf8Lossy();
  @override
  Stream<String> bind(Stream<List<int>> stream) async* {
    await for (final chunk in stream) {
      try {
        yield utf8.decode(chunk, allowMalformed: true);
      } catch (_) {
        yield String.fromCharCodes(chunk);
      }
    }
  }
}
