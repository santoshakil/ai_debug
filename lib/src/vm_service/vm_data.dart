class VmData {
  static Map<String, Object?> cpu(
    Map<String, dynamic> result, {
    required int limit,
  }) {
    final functions = _maps(result['functions']);
    functions.sort(
      (a, b) => _int(b['inclusiveTicks']).compareTo(_int(a['inclusiveTicks'])),
    );
    return {
      'samplePeriodUs': _int(result['samplePeriod']),
      'sampleCount': _int(result['sampleCount']),
      'timeOriginUs': _int(result['timeOriginMicros']),
      'timeExtentUs': _int(result['timeExtentMicros']),
      'maxStackDepth': _int(result['maxStackDepth']),
      'top': [
        for (final item in functions.take(limit))
          {
            'name': _functionName(item),
            'kind': item['kind']?.toString(),
            'inclusiveSamples': _int(item['inclusiveTicks']),
            'exclusiveSamples': _int(item['exclusiveTicks']),
            'uri': item['resolvedUrl']?.toString(),
          },
      ],
      'source': 'vmService',
      'scope': 'one isolate',
    };
  }

  static Map<String, Object?> allocations(
    Map<String, dynamic> result, {
    required int limit,
  }) {
    final members = _maps(result['members'])
      ..sort(
        (a, b) => _int(b['bytesCurrent']).compareTo(_int(a['bytesCurrent'])),
      );
    return {
      'memory': result['memoryUsage'],
      'classes': [
        for (final item in members.take(limit))
          {
            'name': _className(item),
            'bytesCurrent': _int(item['bytesCurrent']),
            'instancesCurrent': _int(item['instancesCurrent']),
            'accumulatedBytes': _int(item['accumulatedSize']),
            'accumulatedInstances': _int(item['instancesAccumulated']),
          },
      ],
      'lastReset': result['dateLastAccumulatorReset'],
      'lastServiceGc': result['dateLastServiceGC'],
      'source': 'vmService',
      'scope': 'one isolate',
    };
  }

  static Map<String, Object?> timeline(
    Map<String, dynamic> result, {
    required int limit,
  }) {
    final events = _maps(result['traceEvents']);
    events.sort((a, b) => _num(a['ts']).compareTo(_num(b['ts'])));
    return {
      'timeOriginUs': _int(result['timeOriginMicros']),
      'timeExtentUs': _int(result['timeExtentMicros']),
      'totalEvents': events.length,
      'returnedEvents': events.length.clamp(0, limit),
      'truncated': events.length > limit,
      'events': [
        for (final event in events.take(limit))
          {
            for (final key in const [
              'name',
              'cat',
              'ph',
              'ts',
              'dur',
              'pid',
              'tid',
            ])
              if (event.containsKey(key)) key: event[key],
          },
      ],
      'source': 'vmService',
      'scope': 'current Dart VM and enabled engine streams',
    };
  }

  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? [
          for (final item in value)
            if (item is Map) Map<String, dynamic>.from(item),
        ]
      : [];

  static String _functionName(Map<String, dynamic> item) {
    final function = item['function'];
    if (function is Map) {
      return function['name']?.toString() ?? '<unnamed>';
    }
    return '<unnamed>';
  }

  static String _className(Map<String, dynamic> item) {
    final cls = item['class'];
    if (cls is Map) return cls['name']?.toString() ?? '<unnamed>';
    return '<unnamed>';
  }

  static int _int(Object? value) => switch (value) {
    int value => value,
    String value => int.tryParse(value) ?? 0,
    _ => 0,
  };

  static num _num(Object? value) => switch (value) {
    num value => value,
    String value => num.tryParse(value) ?? 0,
    _ => 0,
  };
}
