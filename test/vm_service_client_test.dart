import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_debug/src/vm_service/vm_service_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const uri = 'ws://127.0.0.1:8181/ws';

  test(
    'dispose cancels a stalled connection and closes its late socket',
    () async {
      final opening = Completer<WebSocket>();
      final started = Completer<void>();
      final socket = TestWebSocket();
      final client = VmServiceClient.testing(
        serviceUri: () async => Uri.parse(uri),
        connectSocket: (_) {
          started.complete();
          return opening.future;
        },
        connectTimeout: const Duration(hours: 1),
      );
      final call = expectLater(
        client.call('getVM'),
        throwsA(isA<StateError>()),
      );
      await started.future;

      await client.dispose().timeout(const Duration(milliseconds: 200));
      await call.timeout(const Duration(milliseconds: 200));
      expect(client.pendingCallCount, 0);

      opening.complete(socket);
      await pumpEventQueue();

      expect(socket.closeCount, 1);
    },
  );

  test(
    'dispose cancels stalled service discovery before opening a socket',
    () async {
      final discovery = Completer<Uri?>();
      final started = Completer<void>();
      var connections = 0;
      final client = VmServiceClient.testing(
        serviceUri: () {
          started.complete();
          return discovery.future;
        },
        connectSocket: (_) async {
          connections++;
          return TestWebSocket();
        },
        connectTimeout: const Duration(hours: 1),
      );
      final call = expectLater(
        client.call('getVM'),
        throwsA(isA<StateError>()),
      );
      await started.future;

      await client.dispose().timeout(const Duration(milliseconds: 200));
      await call.timeout(const Duration(milliseconds: 200));
      discovery.complete(Uri.parse(uri));
      await pumpEventQueue();

      expect(connections, 0);
    },
  );

  test('a disposed connection cannot replace a new generation', () async {
    final firstOpening = Completer<WebSocket>();
    final firstStarted = Completer<void>();
    final first = TestWebSocket();
    final second = TestWebSocket()..replyToCalls();
    var connections = 0;
    final client = VmServiceClient.testing(
      serviceUri: () async => Uri.parse(uri),
      connectSocket: (_) {
        connections++;
        if (connections == 1) {
          firstStarted.complete();
          return firstOpening.future;
        }
        return Future.value(second);
      },
      connectTimeout: const Duration(hours: 1),
    );
    final oldCall = expectLater(
      client.call('getVM'),
      throwsA(isA<StateError>()),
    );
    await firstStarted.future;
    await client.dispose();

    final newCall = client.call('getVersion');
    firstOpening.complete(first);

    expect(await newCall, {'ok': true});
    await oldCall;
    await pumpEventQueue();
    expect(client.isConnected, isTrue);
    expect(first.closeCount, 1);
    expect(second.closeCount, 0);

    await client.dispose();
  });

  test('connection timeout closes a socket that arrives later', () async {
    final opening = Completer<WebSocket>();
    final socket = TestWebSocket();
    final client = VmServiceClient.testing(
      serviceUri: () async => Uri.parse(uri),
      connectSocket: (_) => opening.future,
      connectTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(client.call('getVM'), throwsA(isA<TimeoutException>()));
    opening.complete(socket);
    await pumpEventQueue();

    expect(socket.closeCount, 1);
    expect(client.isConnected, isFalse);
    await client.dispose();
  });

  test('send failure removes the pending call', () async {
    final socket = TestWebSocket(sendError: StateError('send failed'));
    final client = VmServiceClient.testing(
      serviceUri: () async => Uri.parse(uri),
      connectSocket: (_) async => socket,
    );

    await expectLater(
      client.call('getVM'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'send failed',
        ),
      ),
    );
    expect(client.pendingCallCount, 0);
    await client.dispose();
  });

  test('VM errors stay within their text limit', () async {
    final socket = TestWebSocket();
    socket.onAdd = (raw) {
      final request = jsonDecode(raw! as String) as Map<String, dynamic>;
      socket.addMessage(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': 1, 'message': 'x' * 5000},
        }),
      );
    };
    final client = VmServiceClient.testing(
      serviceUri: () async => Uri.parse(uri),
      connectSocket: (_) async => socket,
    );

    await expectLater(
      client.call('getVM'),
      throwsA(
        isA<VmServiceError>()
            .having((error) => error.message.length, 'length', 4096)
            .having((error) => error.message.endsWith('…'), 'suffix', isTrue),
      ),
    );
    await client.dispose();
  });

  test('accepts bounded profiler responses within the limit', () async {
    final socket = TestWebSocket();
    socket.onAdd = (raw) {
      final request = jsonDecode(raw! as String) as Map<String, dynamic>;
      socket.addMessage(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {'payload': 'x' * (20 * 1024 * 1024)},
        }),
      );
    };
    final client = VmServiceClient.testing(
      serviceUri: () async => Uri.parse(uri),
      connectSocket: (_) async => socket,
    );

    final result = await client.call('getAllocationProfile');

    expect((result['payload'] as String).length, 20 * 1024 * 1024);
    await client.dispose();
  });

  test('dispose bounds socket close and still fails pending calls', () async {
    final neverClosed = Completer<void>();
    final socket = TestWebSocket(closeFuture: neverClosed.future);
    final sent = Completer<void>();
    socket.onAdd = (_) => sent.complete();
    final client = VmServiceClient.testing(
      serviceUri: () async => Uri.parse(uri),
      connectSocket: (_) async => socket,
      callTimeout: const Duration(hours: 1),
      disposeTimeout: const Duration(milliseconds: 20),
    );
    final call = expectLater(client.call('getVM'), throwsA(isA<StateError>()));
    await sent.future;

    await client.dispose().timeout(const Duration(milliseconds: 200));
    await call;
    expect(client.pendingCallCount, 0);
    expect(socket.closeCount, 1);
  });
}

class TestWebSocket implements WebSocket {
  final Object? sendError;
  final Future<void>? closeFuture;
  final _messages = StreamController<dynamic>();
  void Function(Object?)? onAdd;
  var closeCount = 0;
  var open = true;

  TestWebSocket({this.sendError, this.closeFuture});

  void replyToCalls() {
    onAdd = (raw) {
      final request = jsonDecode(raw! as String) as Map<String, dynamic>;
      _messages.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {'ok': true},
        }),
      );
    };
  }

  void addMessage(String message) => _messages.add(message);

  @override
  int get readyState => open ? WebSocket.open : WebSocket.closed;

  @override
  void add(dynamic data) {
    final error = sendError;
    if (error != null) throw error;
    onAdd?.call(data);
  }

  @override
  Future<void> close([int? code, String? reason]) {
    closeCount++;
    open = false;
    return closeFuture ?? Future.value();
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _messages.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
