import 'package:ai_debug/ai_debug.dart' show AiDebug;
import 'package:ai_debug/src/builtins/builtins.dart';
import 'package:ai_debug/src/builtins/legacy_io_tools.dart';
import 'package:ai_debug/src/config.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter_test/flutter_test.dart';

const _diagnostics = {'devtools.focus', 'errors.history', 'errors.status'};
const _logs = {'logs.status'};
const _state = {'state.history', 'state.snapshot', 'state.sources'};
const _resources = {
  'app.lifecycle',
  'app.lifecycle_history',
  'dart_version',
  'device_info',
  'devtools.capabilities',
  'devtools.frames.history',
  'devtools.frames.summary',
  'devtools.resources.history',
  'devtools.resources.sample',
  'devtools.resources.status',
  'devtools.trace.events',
  'devtools.trace.export_chrome',
  'devtools.trace.status',
  'devtools.ui.layers',
  'devtools.ui.render',
  'devtools.ui.semantics',
  'devtools.ui.widgets',
  'displays',
  'memory',
  'runtime.clock',
};
const _isolates = {'isolates.events', 'isolates.status'};
const _screenshots = {'screenshot'};
const _automation = {
  'ui.activate',
  'ui.capabilities',
  'ui.double_tap',
  'ui.drag',
  'ui.find',
  'ui.long_press',
  'ui.pinch',
  'ui.run',
  'ui.scroll',
  'ui.scroll_until',
  'ui.snapshot',
  'ui.tap',
  'ui.wait',
};
const _navigation = {
  'app.back',
  'app.navigate',
  'app.pop_until',
  'app.replace',
  'app.routes',
};
const _network = {
  'network.connect',
  'network.history',
  'network.http_probe',
  'network.interfaces',
  'network.resolve',
  'network.status',
};
const _files = {
  'files.directory_size',
  'files.list',
  'files.read_bytes',
  'files.read_text',
  'files.roots',
  'files.stat',
  'files.walk',
};
const _runtimeControls = {
  'app.lifecycle_clear',
  'devtools.debug_flags',
  'devtools.frames.clear',
  'devtools.frames.start',
  'devtools.frames.stop',
  'devtools.resources.clear',
  'devtools.resources.start',
  'devtools.resources.stop',
  'devtools.trace.clear',
  'devtools.trace.instant',
  'devtools.trace.span_finish',
  'devtools.trace.span_start',
  'devtools.trace.start',
  'devtools.trace.stop',
  'errors.clear',
  'isolates.clear',
  'logs.clear',
  'logs.emit',
  'logs.level',
  'network.clear',
  'runtime.clipboard_get',
  'runtime.clipboard_set',
  'runtime.haptic',
  'runtime.performance_overlay',
  'runtime.reassemble',
  'runtime.schedule_frame',
  'runtime.system_sound',
  'runtime.time_dilation',
  'state.clear',
};
const _telemetry = {
  'telemetry.emit',
  'telemetry.flush',
  'telemetry.start',
  'telemetry.status',
  'telemetry.stop',
};
const _vm = {
  'vm.allocations',
  'vm.cpu',
  'vm.isolates',
  'vm.memory',
  'vm.stack',
  'vm.status',
  'vm.timeline',
};

const _defaultNames = {
  ..._diagnostics,
  ..._logs,
  ..._state,
  ..._resources,
  ..._isolates,
};

const _allNames = {
  ..._defaultNames,
  ..._screenshots,
  ..._automation,
  ..._navigation,
  ..._network,
  ..._files,
  ..._runtimeControls,
  ..._telemetry,
  ..._vm,
};

const legacyFeatureInventory = <String, Object>{
  'replacements': <String, List<String>>{
    'diagnostics': <String>[
      'errors.history',
      'errors.status',
      'devtools.focus',
    ],
    'devtools': <String>[
      'devtools.ui.layers',
      'devtools.ui.render',
      'devtools.ui.semantics',
      'devtools.ui.widgets',
    ],
    'errors': <String>['errors.clear', 'errors.history', 'errors.status'],
    'files': <String>[
      'files.directory_size',
      'files.list',
      'files.read_bytes',
      'files.read_text',
      'files.roots',
      'files.stat',
      'files.walk',
    ],
    'input': <String>[
      'ui.activate',
      'ui.double_tap',
      'ui.drag',
      'ui.find',
      'ui.long_press',
      'ui.pinch',
      'ui.run',
      'ui.scroll',
      'ui.scroll_until',
      'ui.snapshot',
      'ui.tap',
      'ui.wait',
    ],
    'io': <String>[
      'runtime.clipboard_get',
      'runtime.clipboard_set',
      'runtime.haptic',
      'runtime.system_sound',
    ],
    'lifecycle': <String>[
      'app.lifecycle',
      'app.lifecycle_clear',
      'app.lifecycle_history',
    ],
    'logs': <String>['logs.clear', 'logs.emit', 'logs.level', 'logs.status'],
    'navigation': <String>[
      'app.back',
      'app.navigate',
      'app.pop_until',
      'app.replace',
      'app.routes',
    ],
    'network': <String>[
      'network.connect',
      'network.http_probe',
      'network.interfaces',
      'network.resolve',
    ],
    'resources': <String>[
      'devtools.frames.history',
      'devtools.frames.summary',
      'devtools.resources.history',
      'devtools.resources.sample',
      'devtools.resources.status',
      'displays',
      'memory',
    ],
    'runtime': <String>[
      'runtime.clock',
      'runtime.performance_overlay',
      'runtime.reassemble',
      'runtime.schedule_frame',
      'runtime.time_dilation',
    ],
    'screenshot': <String>['screenshot'],
    'state': <String>[
      'state.clear',
      'state.history',
      'state.snapshot',
      'state.sources',
    ],
    'telemetry': <String>[
      'telemetry.emit',
      'telemetry.flush',
      'telemetry.start',
      'telemetry.status',
      'telemetry.stop',
    ],
    'vm': <String>[
      'vm.allocations',
      'vm.cpu',
      'vm.isolates',
      'vm.memory',
      'vm.stack',
      'vm.status',
      'vm.timeline',
    ],
  },
  'excluded': <String, String>{
    'platform_invoke': 'unbounded native capability',
    'env_vars': 'secret exposure',
    'fs_app_dirs': 'requires a platform directory provider',
    'vm_force_gc': 'not a real Dart GC control',
    'fs_disk_free': 'native process and portability risk',
    'network_http_post_json': 'unbounded outbound write',
    'trigger_error': 'deliberate app failure',
    'error_throw': 'deliberate app failure',
    'error_throw_async': 'deliberate app failure',
    'error_assert_fail': 'deliberate app failure',
    'sleep': 'tool queue denial of service',
    'sleep_until': 'tool queue denial of service',
    'system_chrome_set': 'no safe public restore API',
    'set_preferred_orientations': 'no safe public restore API',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(AiDebug.dispose);

  test('all replacement inventory names exist with all feature gates', () {
    final registry = CommandRegistry();
    registerAllBuiltinTools(
      registry,
      AiDebugConfig(
        appId: 'inventory',
        token: 'test',
        allowedFileRoots: const {'/tmp'},
        features: const AiDebugFeatures.all(),
      ),
    );
    final names = registry.all.map((tool) => tool.name).toSet();
    final replacements =
        legacyFeatureInventory['replacements']! as Map<String, List<String>>;

    for (final group in replacements.values) {
      expect(names, containsAll(group));
    }
    expect(names, _allNames);
    final excluded = legacyFeatureInventory['excluded']! as Map<String, String>;
    expect(excluded, hasLength(14));
    expect(names.intersection(excluded.keys.toSet()), isEmpty);
  });

  test('legacy IO is absent without runtime controls', () {
    final registry = CommandRegistry();
    registerAllBuiltinTools(
      registry,
      AiDebugConfig(
        appId: 'inventory',
        token: 'test',
        features: const AiDebugFeatures.none(),
      ),
    );
    expect(
      registry.all.map((tool) => tool.name),
      isNot(contains('runtime.clipboard_get')),
    );
    expect(
      registry.all.map((tool) => tool.name),
      isNot(contains('runtime.haptic')),
    );
  });

  test('the default remote tool set is read only', () {
    final registry = CommandRegistry();
    registerAllBuiltinTools(
      registry,
      AiDebugConfig(appId: 'inventory', token: 'test'),
    );

    expect(registry.all.map((tool) => tool.name).toSet(), _defaultNames);
    for (final tool in registry.all) {
      expect(tool.annotations?['readOnlyHint'], isTrue, reason: tool.name);
    }
  });

  test('none registers no package tools', () {
    final registry = CommandRegistry();
    registerAllBuiltinTools(
      registry,
      AiDebugConfig(
        appId: 'inventory',
        token: 'test',
        features: const AiDebugFeatures.none(),
      ),
    );

    expect(registry.all, isEmpty);
  });

  test('VM allocation controls require runtime controls', () {
    final registry = CommandRegistry();
    registerAllBuiltinTools(
      registry,
      AiDebugConfig(
        appId: 'inventory',
        token: 'test',
        features: const AiDebugFeatures.none(vmService: true),
      ),
    );

    final tool = registry.get('vm.allocations')!;
    final props = tool.inputSchema.asJson['properties']! as Map;
    expect(props, isNot(contains('gc')));
    expect(props, isNot(contains('reset')));
    expect(tool.annotations?['readOnlyHint'], isTrue);
  });

  test('clipboard bounds remain finite', () {
    expect(legacyIoMaxClipboardChars, 65536);
  });

  test('side-effect annotations match remote actions', () {
    final registry = CommandRegistry();
    registerAllBuiltinTools(
      registry,
      AiDebugConfig(
        appId: 'inventory',
        token: 'test',
        allowedFileRoots: const {'/tmp'},
        features: const AiDebugFeatures.all(),
      ),
    );

    for (final name in [
      'network.resolve',
      'network.connect',
      'network.http_probe',
    ]) {
      expect(registry.get(name)!.annotations?['readOnlyHint'], isFalse);
      expect(registry.get(name)!.annotations?['openWorldHint'], isTrue);
    }
    for (final name in [
      'vm.allocations',
      'telemetry.stop',
      'telemetry.flush',
    ]) {
      expect(
        registry.get(name)!.annotations?['destructiveHint'],
        isTrue,
        reason: name,
      );
    }
  });
}
