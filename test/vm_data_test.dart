import 'package:ai_debug/src/vm_service/vm_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CPU summary sorts by inclusive samples and caps output', () {
    final result = VmData.cpu({
      'sampleCount': 10,
      'functions': [
        {
          'inclusiveTicks': 2,
          'exclusiveTicks': 1,
          'function': {'name': 'slow'},
        },
        {
          'inclusiveTicks': 8,
          'exclusiveTicks': 4,
          'function': {'name': 'hot'},
        },
      ],
    }, limit: 1);

    expect(result['sampleCount'], 10);
    final top = result['top'] as List;
    expect(top, hasLength(1));
    expect((top.single as Map)['name'], 'hot');
  });

  test('allocation summary sorts by live bytes', () {
    final result = VmData.allocations({
      'members': [
        {
          'bytesCurrent': 10,
          'class': {'name': 'Small'},
        },
        {
          'bytesCurrent': 30,
          'class': {'name': 'Large'},
        },
      ],
    }, limit: 10);

    final classes = result['classes'] as List;
    expect((classes.first as Map)['name'], 'Large');
  });

  test('timeline strips event arguments and reports truncation', () {
    final result = VmData.timeline({
      'traceEvents': [
        {
          'name': 'b',
          'ts': 2,
          'args': {'secret': 'value'},
        },
        {
          'name': 'a',
          'ts': 1,
          'args': {'secret': 'value'},
        },
      ],
    }, limit: 1);

    expect(result['truncated'], isTrue);
    final event = (result['events'] as List).single as Map;
    expect(event['name'], 'a');
    expect(event, isNot(contains('args')));
  });
}
