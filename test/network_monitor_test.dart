import 'package:ai_debug/src/observability/network_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validates metrics and caps active requests', () {
    final monitor = NetworkMonitor(maxActive: 1);
    expect(
      () => monitor.start(method: '', uri: Uri.parse('https://example.com')),
      throwsArgumentError,
    );
    expect(
      () =>
          monitor.start(method: ' GET ', uri: Uri.parse('https://example.com')),
      throwsArgumentError,
    );
    final request = monitor.start(
      method: 'GET',
      uri: Uri.parse('https://example.com'),
    );
    expect(
      () => monitor.start(
        method: 'GET',
        uri: Uri.parse('https://example.com/next'),
      ),
      throwsStateError,
    );
    expect(() => request.finish(responseBytes: -1), throwsRangeError);
    request.finish(status: 200);
  });

  test('network events redact URL secrets', () {
    final monitor = NetworkMonitor();
    monitor
        .start(
          method: 'get',
          uri: Uri.parse(
            'https://user:secret@example.com/a?token=secret#fragment',
          ),
        )
        .finish(status: 200, responseBytes: 4);

    final event = monitor.history().single.toJson();
    expect(event['url'], 'https://example.com/a?token=%5Bredacted%5D');
    expect(event.toString(), isNot(contains('secret')));
  });

  test('network URLs have finite stored path and query sizes', () {
    final monitor = NetworkMonitor();
    final uri = Uri(
      scheme: 'https',
      host: 'example.com',
      pathSegments: List.filled(100, ''.padRight(500, 'a')),
      queryParameters: {for (var i = 0; i < 100; i++) 'key-$i': 'secret'},
    );
    monitor.start(method: 'GET', uri: uri).finish(status: 200);

    final saved = monitor.history().single.uri;
    expect(saved.pathSegments, hasLength(65));
    expect(saved.pathSegments.first.length, 256);
    expect(saved.queryParameters, hasLength(64));
    expect(saved.toString(), isNot(contains('secret')));
  });

  test('network history is bounded and summarized', () {
    final monitor = NetworkMonitor(capacity: 1);
    monitor
        .start(method: 'get', uri: Uri.parse('https://a.test'))
        .finish(status: 200);
    monitor
        .start(method: 'get', uri: Uri.parse('https://b.test'))
        .fail(StateError('failed'), status: 500);

    expect(monitor.length, 1);
    expect(monitor.dropped, 1);
    expect(monitor.summary()['errors'], 1);
  });

  test('finishing twice records once', () {
    final monitor = NetworkMonitor();
    final request = monitor.start(
      method: 'get',
      uri: Uri.parse('https://example.com'),
    );
    request.finish(status: 200);
    request.finish(status: 201);

    expect(monitor.history(), hasLength(1));
    expect(monitor.history().single.status, 200);
  });

  test(
    'bad failure text finishes the request and dispose clears active work',
    () {
      final monitor = NetworkMonitor();
      final failed = monitor.start(
        method: 'get',
        uri: Uri.parse('https://example.com/fail'),
      );

      expect(() => failed.fail(_BadText()), returnsNormally);
      expect(failed.isFinished, isTrue);
      expect(monitor.activeCount, 0);
      expect(monitor.history().single.error, 'request_failed');

      monitor.start(
        method: 'get',
        uri: Uri.parse('https://example.com/active'),
      );
      expect(monitor.dispose, returnsNormally);
      expect(monitor.activeCount, 0);
      expect(monitor.history(), isEmpty);
    },
  );

  test('failure details are not stored', () {
    final monitor = NetworkMonitor();
    monitor
        .start(method: 'get', uri: Uri.parse('https://example.com'))
        .fail(StateError('token=secret'));

    final event = monitor.history().single.toJson();
    expect(event['error'], 'request_failed');
    expect(event.toString(), isNot(contains('secret')));
  });
}

class _BadText {
  @override
  String toString() => throw StateError('no text');
}
