import 'dart:async';

import '../internal/json_value.dart';

typedef RouteSnapshot = FutureOr<Object?> Function();
typedef RouteNavigate =
    FutureOr<Object?> Function(String location, Map<String, Object?> arguments);
typedef RouteBack = FutureOr<bool> Function();
typedef RouteReplace =
    FutureOr<Object?> Function(String location, Map<String, Object?> arguments);
typedef RoutePopUntil = FutureOr<Object?> Function(String location);

class NavigationAdapter {
  const NavigationAdapter({
    required this.snapshot,
    this.navigate,
    this.back,
    this.replace,
    this.popUntil,
  });

  final RouteSnapshot snapshot;
  final RouteNavigate? navigate;
  final RouteBack? back;
  final RouteReplace? replace;
  final RoutePopUntil? popUntil;

  Future<Object?> read() async =>
      toJsonValue(await Future<Object?>.sync(snapshot));

  Future<Object?> go(String location, Map<String, Object?> arguments) async {
    final action = navigate;
    if (action == null) throw StateError('navigation is read-only');
    return toJsonValue(
      await Future<Object?>.sync(() => action(location, arguments)),
    );
  }

  Future<bool> pop() async {
    final action = back;
    if (action == null) throw StateError('back navigation is not registered');
    return Future<bool>.sync(action);
  }

  Future<Object?> replaceWith(
    String location,
    Map<String, Object?> arguments,
  ) async {
    final action = replace;
    if (action == null) {
      throw StateError('replace navigation is not registered');
    }
    return toJsonValue(
      await Future<Object?>.sync(() => action(location, arguments)),
    );
  }

  Future<Object?> popTo(String location) async {
    final action = popUntil;
    if (action == null) {
      throw StateError('pop-until navigation is not registered');
    }
    return toJsonValue(await Future<Object?>.sync(() => action(location)));
  }
}
