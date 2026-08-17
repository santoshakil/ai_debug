import 'dart:collection';

import 'package:flutter/widgets.dart';

class LifecycleMonitor extends WidgetsBindingObserver {
  LifecycleMonitor({this.capacity = 256}) {
    if (capacity < 1) {
      throw RangeError.range(capacity, 1, null, 'capacity');
    }
  }

  final int capacity;
  final Queue<LifecycleEvent> _events = Queue();
  var _sequence = 0;
  var _dropped = 0;
  var _started = false;

  bool get isStarted => _started;
  int get length => _events.length;
  int get dropped => _dropped;
  AppLifecycleState? get current => WidgetsBinding.instance.lifecycleState;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final state = current;
    if (state != null) _add(state, initial: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _add(state);

  List<LifecycleEvent> history({int? after, int limit = 100}) {
    if (limit < 1) {
      throw RangeError.range(limit, 1, null, 'limit');
    }
    final events = [
      for (final event in _events)
        if (after == null || event.sequence > after) event,
    ];
    if (events.length <= limit) return events;
    return events.sublist(events.length - limit);
  }

  void clear() {
    _events.clear();
    _dropped = 0;
  }

  void dispose() {
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
    clear();
  }

  void _add(AppLifecycleState state, {bool initial = false}) {
    _events.add(
      LifecycleEvent(
        sequence: ++_sequence,
        timestamp: DateTime.now(),
        state: state,
        initial: initial,
      ),
    );
    while (_events.length > capacity) {
      _events.removeFirst();
      _dropped++;
    }
  }
}

class LifecycleEvent {
  const LifecycleEvent({
    required this.sequence,
    required this.timestamp,
    required this.state,
    required this.initial,
  });

  final int sequence;
  final DateTime timestamp;
  final AppLifecycleState state;
  final bool initial;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'timestamp': timestamp.toIso8601String(),
    'timestampMs': timestamp.millisecondsSinceEpoch,
    'state': state.name,
    'initial': initial,
  };
}
