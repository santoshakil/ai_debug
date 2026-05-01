import 'package:flutter/widgets.dart';

import '../registry.dart';

/// Register navigation tools. These require the app to expose a
/// [GlobalKey<NavigatorState>] via [setNavigatorKey] — otherwise the tools
/// return an error explaining how to wire it.
///
/// Tools:
///   * `navigator_push`      — push a named route.
///   * `navigator_pop`       — pop the current route.
///   * `navigator_replace`   — replace the current route with another.
///   * `navigator_stack`     — dump the current route history.
void registerNavigationTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'navigator_push',
    description: 'Push a named route onto the root Navigator.',
    inputSchema: AiDebugSchema.object(
      {
        'name': AiDebugSchema.string(description: 'Named route like /settings'),
        'arguments': AiDebugSchema.object({}),
      },
      required: ['name'],
    ),
    handler: (args) async {
      final nav = _navigatorKey?.currentState;
      if (nav == null) return _notWired();
      final name = args['name'] as String;
      final r = await nav.pushNamed(name, arguments: args['arguments']);
      return {'ok': true, 'result': r?.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'navigator_pop',
    description: 'Pop the top-most route off the root Navigator.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final nav = _navigatorKey?.currentState;
      if (nav == null) return _notWired();
      final popped = await nav.maybePop();
      return {'ok': true, 'popped': popped};
    },
  ));

  registry.add(ToolEntry(
    name: 'navigator_replace',
    description: 'Replace current route with a named route.',
    inputSchema: AiDebugSchema.object(
      {'name': AiDebugSchema.string()},
      required: ['name'],
    ),
    handler: (args) async {
      final nav = _navigatorKey?.currentState;
      if (nav == null) return _notWired();
      final r = await nav.pushReplacementNamed(args['name'] as String);
      return {'ok': true, 'result': r?.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'navigator_pop_until',
    description: 'Pop routes until the named route is the topmost one.',
    inputSchema: AiDebugSchema.object(
      {'name': AiDebugSchema.string()},
      required: ['name'],
    ),
    handler: (args) async {
      final nav = _navigatorKey?.currentState;
      if (nav == null) return _notWired();
      final target = args['name'] as String;
      nav.popUntil((r) => r.settings.name == target);
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'navigator_stack',
    description:
        'Return the current route stack (names + argument summaries) from the root Navigator.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final nav = _navigatorKey?.currentState;
      if (nav == null) return _notWired();
      final routes = <Map<String, dynamic>>[];
      nav.popUntil((r) {
        routes.add({
          'name': r.settings.name,
          'arguments': r.settings.arguments?.toString(),
          'isCurrent': r.isCurrent,
          'isActive': r.isActive,
        });
        return true; // never actually pops, just iterates
      });
      return {'stack': routes, 'count': routes.length};
    },
  ));
}

GlobalKey<NavigatorState>? _navigatorKey;

/// Register the root [NavigatorState] so `navigator_*` tools can drive it.
///
/// ```dart
/// final navKey = GlobalKey<NavigatorState>();
/// AiDebug.setNavigatorKey(navKey);
/// runApp(MaterialApp(navigatorKey: navKey, ...));
/// ```
void setNavigatorStateKey(GlobalKey<NavigatorState>? key) {
  _navigatorKey = key;
}

Map<String, dynamic> _notWired() => const {
      'ok': false,
      'error':
          'Navigator key not set. Call AiDebug.setNavigatorKey(globalKey) + attach '
          'globalKey to MaterialApp.navigatorKey at startup.',
    };
