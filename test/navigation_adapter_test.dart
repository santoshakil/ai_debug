import 'package:ai_debug/src/builtins/navigation_tools.dart';
import 'package:ai_debug/src/navigation/navigation_adapter.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adapter reads and drives registered callbacks', () async {
    String? location;
    String? replaced;
    String? poppedTo;
    final adapter = NavigationAdapter(
      snapshot: () => {'path': '/photos'},
      navigate: (next, args) {
        location = next;
        return args;
      },
      back: () => true,
      replace: (next, args) {
        replaced = next;
        return args;
      },
      popUntil: (next) => poppedTo = next,
    );

    expect(await adapter.read(), {'path': '/photos'});
    expect(await adapter.go('/search', {'query': 'cat'}), {'query': 'cat'});
    expect(location, '/search');
    expect(await adapter.pop(), isTrue);
    expect(await adapter.replaceWith('/map', {'zoom': 3}), {'zoom': 3});
    expect(replaced, '/map');
    expect(await adapter.popTo('/photos'), '/photos');
    expect(poppedTo, '/photos');
  });

  test('missing mutation callbacks fail clearly', () async {
    final adapter = NavigationAdapter(snapshot: () => '/');

    await expectLater(adapter.go('/', const {}), throwsStateError);
    await expectLater(adapter.pop(), throwsStateError);
    await expectLater(adapter.replaceWith('/', const {}), throwsStateError);
    await expectLater(adapter.popTo('/'), throwsStateError);
  });

  test('navigation tools mark route changes as destructive', () async {
    final registry = CommandRegistry();
    addTearDown(registry.dispose);
    registerNavigationTools(registry);

    expect(registry.get('app.routes')!.annotations?['readOnlyHint'], isTrue);
    expect(
      registry.get('app.navigate')!.annotations?['destructiveHint'],
      isTrue,
    );
    expect(registry.get('app.back')!.annotations?['destructiveHint'], isTrue);
    expect(registry.get('app.replace')!.annotations?['openWorldHint'], isTrue);
    expect(
      registry.get('app.pop_until')!.annotations?['destructiveHint'],
      isTrue,
    );
  });
}
