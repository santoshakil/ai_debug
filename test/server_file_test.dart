import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_debug/ai_debug.dart';
import 'package:flutter_test/flutter_test.dart';

import 'server_smoke_test.dart' show request;

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_debug_server_');
    file = File('${root.path}${Platform.pathSeparator}sample.txt');
    await file.writeAsString('0123456789');
    await AiDebug.start(
      appId: 'file-test',
      port: 0,
      allowedFileRoots: {root.path},
      features: const AiDebugFeatures(
        diagnostics: false,
        logs: false,
        state: false,
        resources: false,
        files: true,
      ),
    );
  });

  tearDown(() async {
    await AiDebug.dispose();
    await root.delete(recursive: true);
  });

  test('streams full files and matching HEAD metadata', () async {
    final path = '/api/file?path=${Uri.encodeQueryComponent(file.path)}';
    final get = await request('GET', path);
    expect(get.status, HttpStatus.ok);
    expect(get.body, '0123456789');
    expect(get.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(get.headers.contentLength, 10);

    final head = await request('HEAD', path);
    expect(head.status, HttpStatus.ok);
    expect(head.bytes, isEmpty);
    expect(head.headers.contentLength, 10);
  });

  test('uses inclusive HTTP and exclusive Dart range ends', () async {
    final response = await request(
      'GET',
      '/api/file?path=${Uri.encodeQueryComponent(file.path)}',
      headers: {'range': 'bytes=2-5'},
    );
    expect(response.status, HttpStatus.partialContent);
    expect(response.body, '2345');
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 2-5/10',
    );
    expect(response.headers.contentLength, 4);

    final head = await request(
      'HEAD',
      '/api/file?path=${Uri.encodeQueryComponent(file.path)}',
      headers: {'range': 'bytes=2-5'},
    );
    expect(head.status, HttpStatus.partialContent);
    expect(head.bytes, isEmpty);
    expect(head.headers.contentLength, 4);
    expect(head.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-5/10');
  });

  test('supports open and suffix ranges', () async {
    final path = '/api/file?path=${Uri.encodeQueryComponent(file.path)}';
    expect(
      (await request('GET', path, headers: {'range': 'bytes=7-'})).body,
      '789',
    );
    expect(
      (await request('GET', path, headers: {'range': 'bytes=-3'})).body,
      '789',
    );
  });

  test('rejects invalid and multiple ranges', () async {
    final path = '/api/file?path=${Uri.encodeQueryComponent(file.path)}';
    for (final range in [
      'bytes=20-30',
      'bytes=5-2',
      'bytes=-0',
      'bytes=0-1,3-4',
    ]) {
      final response = await request('GET', path, headers: {'range': range});
      expect(response.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */10',
      );
    }
  });

  test('rejects paths outside configured roots', () async {
    final outside = File(
      '${root.parent.path}${Platform.pathSeparator}outside.txt',
    );
    await outside.writeAsString('no');
    addTearDown(() => outside.delete());
    final response = await request(
      'GET',
      '/api/file?path=${Uri.encodeQueryComponent(outside.path)}',
    );
    expect(response.status, HttpStatus.forbidden);
  });

  test('allows at most two file streams at once', () async {
    final large = File('${root.path}${Platform.pathSeparator}large.bin');
    await large.open(mode: FileMode.write).then((handle) async {
      await handle.truncate(64 * 1024 * 1024);
      await handle.close();
    });
    final path = '/api/file?path=${Uri.encodeQueryComponent(large.path)}';
    const range = 'bytes=0-4194303';
    final first = await holdFileResponse(path, range: range);
    final second = await holdFileResponse(path, range: range);
    try {
      final limited = await request('GET', path, headers: {'range': range});
      expect(limited.status, HttpStatus.tooManyRequests);
      expect(limited.headers.value(HttpHeaders.retryAfterHeader), '1');
    } finally {
      await first.subscription.cancel();
      first.socket.destroy();
      await second.subscription.cancel();
      second.socket.destroy();
    }
  });
}

Future<({Socket socket, StreamSubscription<List<int>> subscription})>
holdFileResponse(String path, {String? range}) async {
  final socket = await Socket.connect(
    AiDebug.endpointHost!,
    AiDebug.endpointPort!,
  );
  final ready = Completer<void>();
  final header = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> subscription;
  subscription = socket.listen(
    (chunk) {
      if (ready.isCompleted) return;
      header.add(chunk);
      if (ascii
          .decode(header.toBytes(), allowInvalid: true)
          .contains('\r\n\r\n')) {
        subscription.pause();
        ready.complete();
      }
    },
    onError: ready.completeError,
    onDone: () {
      if (!ready.isCompleted) {
        ready.completeError(StateError('file response closed early'));
      }
    },
  );
  final rangeHeader = range == null ? '' : 'Range: $range\r\n';
  socket.write(
    'GET $path HTTP/1.1\r\n'
    'Host: ${AiDebug.endpointHost}:${AiDebug.endpointPort}\r\n'
    'Authorization: Bearer ${AiDebug.token}\r\n'
    '$rangeHeader'
    'Connection: close\r\n'
    '\r\n',
  );
  await socket.flush();
  await ready.future.timeout(const Duration(seconds: 2));
  return (socket: socket, subscription: subscription);
}
