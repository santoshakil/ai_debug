import 'package:flutter/widgets.dart';

import '../registry.dart';

/// Lifecycle + route history tracking. Both observers self-register the first
/// time their tool is registered, so the buffer fills from app start onward.
class _LifeEvt {
  final DateTime when;
  final String state;
  _LifeEvt(this.when, this.state);
  Map<String, dynamic> toJson() =>
      {'when': when.toIso8601String(), 'whenMs': when.millisecondsSinceEpoch, 'state': state};
}

final _lifeBuf = <_LifeEvt>[];

class _LifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifeBuf.add(_LifeEvt(DateTime.now(), state.name));
    while (_lifeBuf.length > 256) {
      _lifeBuf.removeAt(0);
    }
  }
}

bool _lifecycleAttached = false;

void _ensureLifecycleObserver() {
  if (_lifecycleAttached) return;
  _lifecycleAttached = true;
  WidgetsBinding.instance.addObserver(_LifecycleObserver());
  // Capture the current state at attach time.
  final s = WidgetsBinding.instance.lifecycleState;
  _lifeBuf.add(_LifeEvt(DateTime.now(), (s ?? AppLifecycleState.resumed).name));
}

void registerObserverTools(CommandRegistry registry) {
  _ensureLifecycleObserver();

  registry.add(ToolEntry(
    name: 'lifecycle_history',
    description:
        'AppLifecycleState transitions captured since app start. Each entry: when, whenMs, state. '
        'States: resumed, inactive, paused, detached, hidden.',
    inputSchema: AiDebugSchema.object({
      'limit': AiDebugSchema.integer(default_: 64, min: 1, max: 256),
    }),
    handler: (args) async {
      _ensureLifecycleObserver();
      final limit = (args['limit'] as num?)?.toInt() ?? 64;
      final tail = _lifeBuf.length > limit
          ? _lifeBuf.sublist(_lifeBuf.length - limit)
          : _lifeBuf;
      return {'count': tail.length, 'transitions': tail.map((e) => e.toJson()).toList()};
    },
  ));

  registry.add(ToolEntry(
    name: 'lifecycle_current',
    description: 'Current AppLifecycleState (or resumed if unset).',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final s = WidgetsBinding.instance.lifecycleState;
      return {'state': (s ?? AppLifecycleState.resumed).name};
    },
  ));

  registry.add(ToolEntry(
    name: 'lifecycle_clear_history',
    description: 'Clear lifecycle event buffer.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      _lifeBuf.clear();
      return {'ok': true};
    },
  ));
}
