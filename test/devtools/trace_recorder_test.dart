import 'dart:convert';

import 'package:ai_debug/src/devtools/trace_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trace recorder captures spans and Chrome trace events', () {
    var clock = 100;
    final recorder = TraceRecorder(
      traceClock: () => clock,
      wallClock: () => DateTime.utc(2026, 1, 2),
    );
    addTearDown(recorder.dispose);

    recorder.start();
    final span = recorder.startSpan(
      'load',
      category: 'work',
      arguments: {'route': '/photos'},
    );
    clock = 450;
    span!.finish(arguments: {'result': 'ok'});
    clock = 500;
    recorder.instant('ready');

    final events = recorder.events();
    expect(events, hasLength(2));
    expect(events.first.durationMicros, 350);
    expect(events.first.arguments, {'route': '/photos', 'result': 'ok'});

    final export = recorder.exportChromeTrace();
    final chrome = (export['traceEvents'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(chrome.first['ph'], 'X');
    expect(chrome.first['dur'], 350);
    expect(chrome.last['ph'], 'i');
    expect(() => jsonEncode(export), returnsNormally);
  });

  test('trace history and open spans stay bounded', () {
    var clock = 0;
    final recorder = TraceRecorder(
      capacity: 1,
      maxOpenSpans: 1,
      traceClock: () => clock++,
    );
    addTearDown(recorder.dispose);
    recorder.start();

    final open = recorder.startSpan('open');
    expect(() => recorder.startSpan('extra'), throwsStateError);
    recorder.stop();
    expect(open!.isFinished, isTrue);
    expect(recorder.events().single.arguments['cancelled'], isTrue);

    recorder.start();
    recorder.instant('next');
    expect(recorder.events().single.name, 'next');
    expect(recorder.droppedEvents, 1);
    expect(recorder.status()['limits'], contains('vmTimeline'));
  });

  test('disabled and disposed recorder never leaks work', () async {
    final recorder = TraceRecorder();
    expect(recorder.startSpan('ignored'), isNull);
    expect(await recorder.timeAsync('ignored', () async => 3), 3);
    expect(recorder.events(), isEmpty);

    recorder.dispose();
    recorder.dispose();
    expect(recorder.start, throwsStateError);
    expect(() => recorder.instant('late'), throwsStateError);
  });

  test('trace arguments are JSON-safe and globally bounded', () {
    final recorder = TraceRecorder();
    addTearDown(recorder.dispose);
    recorder.start();
    recorder.instant(
      'values',
      arguments: {
        'nan': double.nan,
        'infinity': double.infinity,
        'long': 'x' * 20000,
        'list': List<int>.generate(1000, (index) => index),
      },
    );

    final event = recorder.events().single;
    expect(event.arguments['nan'], '<non-finite:NaN>');
    expect((event.arguments['long']! as String).length, lessThan(1100));
    expect((event.arguments['list']! as List<Object?>).length, 101);
    expect(() => jsonEncode(recorder.exportChromeTrace()), returnsNormally);
  });

  test('bad argument text never prevents traced work', () async {
    final recorder = TraceRecorder();
    addTearDown(recorder.dispose);
    recorder.start();
    var syncRan = false;
    var asyncRan = false;

    final sync = recorder.timeSync('sync', () {
      syncRan = true;
      return 1;
    }, arguments: {'bad': _BadText()});
    final async = await recorder.timeAsync('async', () async {
      asyncRan = true;
      return 2;
    }, arguments: {'bad': _BadText()});
    final span = recorder.startSpan('finish')!;
    span.finish(arguments: {'bad': _BadText()});
    recorder.instant(
      'nested',
      arguments: {
        'map': {_BadText(): _BadText()},
      },
    );

    expect(sync, 1);
    expect(async, 2);
    expect(syncRan, isTrue);
    expect(asyncRan, isTrue);
    expect(recorder.openSpanCount, 0);
    expect(recorder.events().first.arguments['bad'], '<unavailable>');
    expect(recorder.events().last.arguments['map'], {
      '<unavailable>': '<unavailable>',
    });
  });
}

class _BadText {
  @override
  String toString() => throw StateError('no text');
}
