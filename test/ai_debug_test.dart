import 'dart:async';
import 'dart:io';

import 'package:ai_debug/ai_debug.dart';
import 'package:ai_debug/src/builtins/diagnostics_tools.dart';
import 'package:ai_debug/src/builtins/log_tools.dart';
import 'package:ai_debug/src/builtins/runtime_tools.dart';
import 'package:ai_debug/src/builtins/screenshot_tool.dart'
    show screenshotRootKey;
import 'package:ai_debug/src/builtins/time_tools.dart';
import 'package:ai_debug/src/internal/bridge.dart';
import 'package:ai_debug/src/registry.dart' show CommandRegistry;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async => AiDebug.dispose());
  tearDown(() async {
    await AiDebug.dispose();
    AiDebug.clearRegisteredTools();
    await AiDebug.clearStateInspectors();
    AiDebug.clearNavigation();
    AiDebug.clearScreenshotRoot();
  });

  test('starts, rejects a different config, and restarts', () async {
    final config = AiDebugConfig(
      appId: 'lifecycle',
      port: 0,
      features: AiDebugFeatures.none(),
    );
    await AiDebug.start(config: config);

    expect(AiDebug.isStarted, isTrue);
    expect(AiDebug.endpointHost, '127.0.0.1');
    expect(AiDebug.endpointPort, greaterThan(0));
    await AiDebug.start(config: config);
    await expectLater(
      AiDebug.start(
        config: AiDebugConfig(
          appId: 'different',
          port: 0,
          features: AiDebugFeatures.none(),
        ),
      ),
      throwsStateError,
    );

    await AiDebug.dispose();
    await AiDebug.start(config: config);
    expect(AiDebug.isStarted, isTrue);
  });

  test('config cannot be mixed with shorthand settings', () async {
    await expectLater(
      AiDebug.start(
        config: AiDebugConfig(
          appId: 'config-only',
          port: 0,
          features: const AiDebugFeatures.none(),
        ),
        port: 1,
      ),
      throwsArgumentError,
    );
  });

  test('shorthand start is idempotent with a generated token', () async {
    await AiDebug.start(
      appId: 'shorthand',
      port: 0,
      features: const AiDebugFeatures.none(),
    );
    final token = AiDebug.token;

    await AiDebug.start(
      appId: 'shorthand',
      port: 0,
      features: const AiDebugFeatures.none(),
    );
    expect(AiDebug.token, token);
  });

  test('dispose waits for a concurrent start', () async {
    final start = AiDebug.start(
      config: AiDebugConfig(
        appId: 'start-stop',
        port: 0,
        features: AiDebugFeatures.none(),
      ),
    );
    final stop = AiDebug.dispose();

    await Future.wait([start, stop]);
    expect(AiDebug.isStarted, isFalse);
    expect(AiDebug.endpointPort, isNull);
  });

  test('start waits for a concurrent dispose', () async {
    await AiDebug.start(
      config: AiDebugConfig(
        appId: 'before',
        port: 0,
        features: AiDebugFeatures.none(),
      ),
    );
    final stop = AiDebug.dispose();
    final start = AiDebug.start(
      config: AiDebugConfig(
        appId: 'after',
        port: 0,
        features: AiDebugFeatures.none(),
      ),
    );

    await Future.wait([stop, start]);
    expect(AiDebug.isStarted, isTrue);
  });

  test('failed bind leaves the bridge restartable', () async {
    final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      await expectLater(
        AiDebug.start(
          config: AiDebugConfig(
            appId: 'blocked',
            port: occupied.port,
            features: const AiDebugFeatures.none(),
          ),
        ),
        throwsA(isA<SocketException>()),
      );
    } finally {
      await occupied.close(force: true);
    }

    expect(AiDebug.isStarted, isFalse);
    await AiDebug.start(
      config: AiDebugConfig(
        appId: 'recovered',
        port: 0,
        features: AiDebugFeatures.none(),
      ),
    );
    expect(AiDebug.isStarted, isTrue);
  });

  test('does not change the app logging level', () async {
    final previous = Logger.root.level;
    Logger.root.level = Level.OFF;
    try {
      await AiDebug.start(
        config: AiDebugConfig(
          appId: 'logging',
          port: 0,
          features: AiDebugFeatures.none(),
        ),
      );
      expect(Logger.root.level, Level.OFF);
    } finally {
      Logger.root.level = previous;
    }
  });

  test('public telemetry APIs require the active feature', () async {
    expect(
      () => AiDebug.startTelemetry(
        collectorUrl: 'http://127.0.0.1:1',
        appId: 'app',
      ),
      throwsStateError,
    );
    await AiDebug.start(
      appId: 'no-telemetry',
      port: 0,
      features: const AiDebugFeatures.none(),
    );

    expect(
      () => AiDebug.startTelemetry(
        collectorUrl: 'http://127.0.0.1:1',
        appId: 'app',
      ),
      throwsStateError,
    );
    expect(() => AiDebug.telemetryEmit(kind: 'event'), throwsStateError);
    expect(AiDebug.telemetryFlush, throwsStateError);
  });

  test('custom tools survive dispose and restart', () async {
    AiDebug.register(
      name: 'app.echo',
      description: 'echo',
      inputSchema: AiDebugSchema.map(),
      handler: (args) => args,
    );
    final config = AiDebugConfig(
      appId: 'custom-restart',
      port: 0,
      features: const AiDebugFeatures.none(),
    );

    await AiDebug.start(config: config);
    expect((await Bridge.I.registry.dispatch('app.echo', {'value': 1})).json, {
      'value': 1,
    });
    await AiDebug.dispose();
    await AiDebug.start(config: config);
    expect((await Bridge.I.registry.dispatch('app.echo', {'value': 2})).json, {
      'value': 2,
    });
  });

  testWidgets('app registrations survive dispose and restart', (tester) async {
    final root = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: root,
            child: const SizedBox.square(dimension: 20),
          ),
        ),
      ),
    );
    AiDebug.register(
      name: 'app.echo',
      description: 'echo',
      handler: (_) => const {'ok': true},
    );
    AiDebug.registerStateInspectorSync('session', () => const {'user': 7});
    AiDebug.setNavigation(
      NavigationAdapter(snapshot: () => const {'location': '/photos'}),
    );
    AiDebug.setScreenshotRoot(root);
    final config = AiDebugConfig(
      appId: 'registrations',
      port: 0,
      features: const AiDebugFeatures(
        diagnostics: false,
        logs: false,
        state: true,
        resources: false,
        screenshots: true,
        navigation: true,
        isolates: false,
      ),
    );

    await tester.runAsync(() async {
      for (var run = 0; run < 2; run++) {
        await AiDebug.start(config: config);
        expect((await Bridge.I.registry.dispatch('app.echo', const {})).json, {
          'ok': true,
        });
        expect(
          (await Bridge.I.registry.dispatch('state.snapshot', const {
            'name': 'session',
          })).json,
          containsPair('value', {'user': 7}),
        );
        expect(
          (await Bridge.I.registry.dispatch('app.routes', const {})).json,
          {'location': '/photos'},
        );
        expect(Bridge.I.registry.get('screenshot'), isNotNull);
        expect(screenshotRootKey, same(root));
        await AiDebug.dispose();
      }
    });
  });

  test('state subscriptions stop and resume with the server', () async {
    final changes = StreamController<Object?>.broadcast();
    addTearDown(changes.close);
    AiDebug.registerStateSource(
      StateSource(name: 'session', snapshot: () => 1, changes: changes.stream),
    );
    final config = AiDebugConfig(
      appId: 'state-lifecycle',
      port: 0,
      features: const AiDebugFeatures(
        diagnostics: false,
        logs: false,
        state: true,
        resources: false,
        isolates: false,
      ),
    );

    expect(changes.hasListener, isFalse);
    await AiDebug.start(config: config);
    expect(changes.hasListener, isTrue);
    await AiDebug.dispose();
    expect(changes.hasListener, isFalse);
    await AiDebug.start(config: config);
    expect(changes.hasListener, isTrue);
  });

  test(
    'state stream factory creates a fresh subscription after restart',
    () async {
      final streams = <StreamController<Object?>>[];
      AiDebug.registerStateSource(
        StateSource(
          name: 'session',
          snapshot: () => 1,
          changesFactory: () {
            final stream = StreamController<Object?>();
            streams.add(stream);
            return stream.stream;
          },
        ),
      );
      addTearDown(() async {
        for (final stream in streams) {
          await stream.close();
        }
      });
      final config = AiDebugConfig(
        appId: 'state-stream-factory',
        port: 0,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: true,
          resources: false,
          isolates: false,
        ),
      );

      await AiDebug.start(config: config);
      expect(streams, hasLength(1));
      expect(streams.single.hasListener, isTrue);
      await AiDebug.dispose();
      expect(streams.single.hasListener, isFalse);
      await AiDebug.start(config: config);
      expect(streams, hasLength(2));
      expect(streams.last.hasListener, isTrue);
    },
  );

  test('persistent state sources reject one-shot change streams', () {
    final changes = StreamController<Object?>();
    addTearDown(() {
      unawaited(changes.close());
    });

    expect(
      () => AiDebug.registerStateSource(
        StateSource(
          name: 'session',
          snapshot: () => 1,
          changes: changes.stream,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('state sources reject two change streams at registration', () {
    final changes = StreamController<Object?>.broadcast();
    addTearDown(changes.close);

    expect(
      () => AiDebug.registerStateSource(
        StateSource(
          name: 'session',
          snapshot: () => 1,
          changes: changes.stream,
          changesFactory: () => changes.stream,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('custom tool inventory is fixed while running', () async {
    AiDebug.register(
      name: 'app.saved',
      description: 'saved',
      handler: (_) => const {'ok': true},
    );
    await AiDebug.start(
      appId: 'fixed-tools',
      port: 0,
      features: const AiDebugFeatures.none(),
    );

    expect(
      () => AiDebug.register(
        name: 'app.late',
        description: 'late',
        handler: (_) => null,
      ),
      throwsStateError,
    );
    expect(() => AiDebug.unregister('app.saved'), throwsStateError);
    expect(AiDebug.clearRegisteredTools, throwsStateError);
    expect((await Bridge.I.registry.dispatch('app.saved', const {})).json, {
      'ok': true,
    });

    await AiDebug.dispose();
    expect(AiDebug.unregister('app.saved'), isTrue);
    expect(AiDebug.unregister('list_apps'), isFalse);
  });

  test('a later feature cannot be shadowed by a custom tool', () async {
    AiDebug.register(
      name: 'app.routes',
      description: 'custom routes',
      handler: (_) => null,
    );
    await AiDebug.start(
      appId: 'collision',
      port: 0,
      features: const AiDebugFeatures.none(),
    );
    await AiDebug.dispose();

    await expectLater(
      AiDebug.start(
        appId: 'collision',
        port: 0,
        features: const AiDebugFeatures(
          diagnostics: false,
          logs: false,
          state: false,
          resources: false,
          navigation: true,
          isolates: false,
        ),
      ),
      throwsStateError,
    );
    expect(AiDebug.isStarted, isFalse);

    expect(AiDebug.unregister('app.routes'), isTrue);
    await AiDebug.start(
      appId: 'collision',
      port: 0,
      features: const AiDebugFeatures(
        diagnostics: false,
        logs: false,
        state: false,
        resources: false,
        navigation: true,
        isolates: false,
      ),
    );
    expect(Bridge.I.registry.get('app.routes'), isNotNull);
  });

  test('app registrations clear only through their own APIs', () async {
    final root = GlobalKey();
    AiDebug.registerStateInspectorSync('session', () => 1);
    AiDebug.setNavigation(NavigationAdapter(snapshot: () => '/'));
    AiDebug.setScreenshotRoot(root);

    expect(await AiDebug.unregisterStateInspector('missing'), isFalse);
    expect(await AiDebug.unregisterStateInspector('session'), isTrue);
    AiDebug.registerStateInspectorSync('session', () => 2);
    await AiDebug.clearStateInspectors();
    AiDebug.clearNavigation();
    AiDebug.clearScreenshotRoot();

    await AiDebug.start(
      appId: 'cleared-registrations',
      port: 0,
      features: const AiDebugFeatures(
        diagnostics: false,
        logs: false,
        state: true,
        resources: false,
        navigation: true,
        isolates: false,
      ),
    );
    expect(
      (await Bridge.I.registry.dispatch('state.sources', const {})).json,
      containsPair('count', 0),
    );
    await expectLater(
      Bridge.I.registry.dispatch('app.routes', const {}),
      throwsStateError,
    );
  });

  testWidgets('dispose restores owned runtime controls', (tester) async {
    Future<T> pumpUntil<T>(Future<T> future) async {
      var done = false;
      future.then<void>((_) => done = true, onError: (_) => done = true);
      for (var i = 0; i < 600 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(done, isTrue);
      return future;
    }

    final oldLevel = Logger.root.level;
    final oldDilation = timeDilation;
    final oldOverlay = WidgetsApp.showPerformanceOverlayOverride;
    final oldPaintSize = debugPaintSizeEnabled;
    try {
      final registry = CommandRegistry();
      registerLogTools(registry, controls: true);
      registerTimeTools(registry, controls: true);
      registerRuntimeTools(registry);
      registerDiagnosticsTools(registry, controls: true);
      Logger.root.level = Level.INFO;
      timeDilation = 1;
      WidgetsApp.showPerformanceOverlayOverride = false;
      debugPaintSizeEnabled = false;
      await registry.dispatch('logs.level', {'level': 'OFF'});
      await registry.dispatch('runtime.time_dilation', {'factor': 2});
      await pumpUntil(
        registry.dispatch('runtime.performance_overlay', {'enabled': true}),
      );
      await pumpUntil(
        registry.dispatch('devtools.debug_flags', {'paintSize': true}),
      );

      disposeLogTools();
      disposeTimeTools();
      final overlayChanged = disposeRuntimeTools();
      final flagsChanged = disposeDiagnosticsTools();
      if (overlayChanged || flagsChanged) {
        await pumpUntil(WidgetsBinding.instance.reassembleApplication());
      }
      expect(Logger.root.level, Level.INFO);
      expect(timeDilation, 1);
      expect(WidgetsApp.showPerformanceOverlayOverride, isFalse);
      expect(debugPaintSizeEnabled, isFalse);
    } finally {
      Logger.root.level = oldLevel;
      timeDilation = oldDilation;
      WidgetsApp.showPerformanceOverlayOverride = oldOverlay;
      debugPaintSizeEnabled = oldPaintSize;
    }
  });

  test('all tools register and start together', () async {
    await AiDebug.start(
      config: AiDebugConfig(
        appId: 'all-tools',
        port: 0,
        allowedFileRoots: {Directory.systemTemp.path},
        features: const AiDebugFeatures.all(discovery: false),
      ),
    );

    expect(AiDebug.isStarted, isTrue);
  });
}
