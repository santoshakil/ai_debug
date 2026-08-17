import '../devtools/frame_monitor.dart';
import '../devtools/resource_monitor.dart';
import '../devtools/trace_recorder.dart';
import '../devtools/ui_inspector.dart';
import '../registry.dart';
import '../vm_service/vm_service_client.dart';

class DevToolsRuntime {
  DevToolsRuntime({
    ResourceMonitor? resources,
    FrameMonitor? frames,
    UiInspector? ui,
    TraceRecorder? trace,
  }) : resources = resources ?? ResourceMonitor(),
       frames = frames ?? FrameMonitor(),
       ui = ui ?? const UiInspector(),
       trace = trace ?? TraceRecorder();

  final ResourceMonitor resources;
  final FrameMonitor frames;
  final UiInspector ui;
  final TraceRecorder trace;

  final Map<int, TraceSpan> _remoteSpans = <int, TraceSpan>{};
  int _nextSpanId = 0;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  Map<String, Object?> capabilities({bool vmServiceEnabled = false}) => {
    'source': 'ai_debug-devtools',
    'scope': 'current app process and Flutter engine',
    'inProcess': const {
      'resourceSamples': true,
      'frameTimings': true,
      'widgetTree': true,
      'renderTree': true,
      'semanticsTree': true,
      'instrumentedTrace': true,
    },
    'vmService': {
      'enabled': vmServiceEnabled,
      'connected': vmServiceEnabled && VmServiceClient.instance.isConnected,
      'source': 'Dart VM service WebSocket',
    },
    'limits': const {
      'cpuHeapGcAllocations':
          'Require the optional VM service connection or host tooling.',
      'engineTimeline':
          'Full Dart and engine timeline events require VM service.',
      'nativeResources':
          'GPU, thermal, battery, and native heap require platform or host tooling.',
      'releaseMode':
          'VM service and debug-only framework details may be absent in release builds.',
    },
  };

  int? startRemoteSpan(
    String name, {
    String category = 'remote',
    Map<String, Object?> arguments = const {},
  }) {
    _checkActive();
    final span = trace.startSpan(
      name,
      category: category,
      arguments: arguments,
    );
    if (span == null) return null;
    final id = ++_nextSpanId;
    _remoteSpans[id] = span;
    return id;
  }

  void finishRemoteSpan(int id, {Map<String, Object?> arguments = const {}}) {
    _checkActive();
    final span = _remoteSpans.remove(id);
    if (span == null || span.isFinished) {
      throw StateError('unknown or finished trace span: $id');
    }
    span.finish(arguments: arguments);
  }

  void stopTrace() {
    trace.stop();
    _remoteSpans.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    resources.dispose();
    frames.dispose();
    stopTrace();
    trace.dispose();
    _disposed = true;
  }

  void _checkActive() {
    if (_disposed) throw StateError('DevTools runtime is disposed');
  }
}

DevToolsRuntime? _runtime;

DevToolsRuntime get devToolsRuntime => _runtime ??= DevToolsRuntime();

Future<void> disposeDevToolsTools() async {
  final runtime = _runtime;
  _runtime = null;
  await runtime?.dispose();
}

DevToolsRuntime registerDevToolsTools(
  CommandRegistry registry, {
  DevToolsRuntime? runtime,
  bool startMonitors = true,
  bool controls = false,
  bool vmServiceEnabled = false,
}) {
  final tools = runtime ?? devToolsRuntime;
  if (tools.isDisposed) throw StateError('DevTools runtime is disposed');
  if (startMonitors) {
    tools.resources.start();
    tools.frames.start();
  }

  registry.add(
    ToolEntry(
      name: 'devtools.capabilities',
      title: 'DevTools capabilities',
      description:
          'Report in-process DevTools support and what needs a VM service or host tool.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => tools.capabilities(vmServiceEnabled: vmServiceEnabled),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.resources.sample',
      title: 'Inspect app resources',
      description:
          'Read process RSS, Flutter image cache, scheduler, view, and refresh data without changing history.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'sample': tools.resources.inspectNow(),
        'limits': _resourceLimits,
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.resources.status',
      title: 'Resource monitor status',
      description: 'Read bounded resource monitor state and its latest sample.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => tools.resources.status(),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.resources.history',
      title: 'Resource sample history',
      description: 'Read the newest bounded in-process resource samples.',
      inputSchema: _limitSchema(300, 60),
      annotations: _readOnly,
      handler: (args) {
        final samples = tools.resources.history(
          limit: args['limit'] as int? ?? 60,
        );
        return {
          'source': 'app-process',
          'scope': 'current process and current Flutter engine',
          'count': samples.length,
          'capacity': tools.resources.capacity,
          'droppedSamples': tools.resources.droppedSamples,
          'samples': [for (final sample in samples) sample.toJson()],
          'limits': _resourceLimits,
        };
      },
    ),
  );

  if (controls) {
    registry.add(
      ToolEntry(
        name: 'devtools.resources.start',
        title: 'Start resource monitor',
        description:
            'Start the bounded one-second in-process resource sampler.',
        inputSchema: AiDebugSchema.object({
          'sample_immediately': AiDebugSchema.boolean(default_: true),
        }),
        annotations: _control,
        handler: (args) {
          tools.resources.start(
            sampleImmediately: args['sample_immediately'] as bool? ?? true,
          );
          return tools.resources.status();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.resources.stop',
        title: 'Stop resource monitor',
        description: 'Stop sampling while keeping its bounded history.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _control,
        handler: (_) {
          tools.resources.stop();
          return tools.resources.status();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.resources.clear',
        title: 'Clear resource history',
        description: 'Clear resource samples and the dropped-sample count.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _destructive,
        handler: (_) {
          tools.resources.clear();
          return tools.resources.status();
        },
      ),
    );
  }

  registry.add(
    ToolEntry(
      name: 'devtools.frames.summary',
      title: 'Frame performance summary',
      description:
          'Summarize refresh-aware Flutter frame timings and independent miss classes.',
      inputSchema: _limitSchema(600, 120),
      annotations: _readOnly,
      handler: (args) =>
          tools.frames.summary(limit: args['limit'] as int? ?? 120),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.frames.history',
      title: 'Frame timing history',
      description:
          'Read the newest bounded, refresh-aware Flutter frame samples.',
      inputSchema: _limitSchema(600, 120),
      annotations: _readOnly,
      handler: (args) {
        final frames = tools.frames.history(
          limit: args['limit'] as int? ?? 120,
        );
        return {
          'source': 'flutter-frame-timing',
          'scope': 'all frame timings reported to the current Flutter engine',
          'count': frames.length,
          'capacity': tools.frames.capacity,
          'droppedSamples': tools.frames.droppedSamples,
          'frames': [for (final frame in frames) frame.toJson()],
          'limits': _frameLimits,
        };
      },
    ),
  );

  if (controls) {
    registry.add(
      ToolEntry(
        name: 'devtools.frames.start',
        title: 'Start frame monitor',
        description: 'Attach the bounded Flutter frame timing collector.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _control,
        handler: (_) {
          tools.frames.start();
          return tools.frames.summary();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.frames.stop',
        title: 'Stop frame monitor',
        description:
            'Detach the frame collector while keeping its bounded history.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _control,
        handler: (_) {
          tools.frames.stop();
          return tools.frames.summary();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.frames.clear',
        title: 'Clear frame history',
        description: 'Clear frame samples and the dropped-sample count.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _destructive,
        handler: (_) {
          tools.frames.clear();
          return tools.frames.summary();
        },
      ),
    );
  }

  registry.add(
    ToolEntry(
      name: 'devtools.ui.widgets',
      title: 'Inspect widget tree',
      description:
          'Read a bounded structured Flutter element and widget tree snapshot.',
      inputSchema: _treeSchema(includeStringLength: true),
      annotations: _readOnly,
      handler: (args) => tools.ui.widgetTree(
        maxNodes: args['max_nodes'] as int? ?? 500,
        maxDepth: args['max_depth'] as int? ?? 50,
        maxStringLength: args['max_string_length'] as int? ?? 200,
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.ui.render',
      title: 'Inspect render tree',
      description:
          'Read bounded structured render objects, bounds, and per-view roots.',
      inputSchema: _treeSchema(),
      annotations: _readOnly,
      handler: (args) => tools.ui.renderTree(
        maxNodes: args['max_nodes'] as int? ?? 500,
        maxDepth: args['max_depth'] as int? ?? 50,
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.ui.layers',
      title: 'Inspect layer tree',
      description: 'Read bounded Flutter debug layers for every render view.',
      inputSchema: _treeSchema(),
      annotations: _readOnly,
      handler: (args) => tools.ui.layerTree(
        maxNodes: args['max_nodes'] as int? ?? 500,
        maxDepth: args['max_depth'] as int? ?? 50,
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.ui.semantics',
      title: 'Inspect semantics tree',
      description:
          'Read bounded Flutter semantics after one frame, including actions and state flags.',
      inputSchema: AiDebugSchema.object({
        'max_nodes': AiDebugSchema.integer(min: 1, max: 10000, default_: 500),
        'max_depth': AiDebugSchema.integer(min: 0, max: 200, default_: 50),
        'max_string_length': AiDebugSchema.integer(
          min: 1,
          max: 10000,
          default_: 200,
        ),
        'settle_timeout_ms': AiDebugSchema.integer(
          min: 1,
          max: 10000,
          default_: 1000,
        ),
      }),
      annotations: _readOnly,
      handler: (args) => tools.ui.semanticsTree(
        maxNodes: args['max_nodes'] as int? ?? 500,
        maxDepth: args['max_depth'] as int? ?? 50,
        maxStringLength: args['max_string_length'] as int? ?? 200,
        settleTimeout: Duration(
          milliseconds: args['settle_timeout_ms'] as int? ?? 1000,
        ),
      ),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.trace.status',
      title: 'Trace recorder status',
      description: 'Read bounded in-process trace recorder state and limits.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => tools.trace.status(),
    ),
  );

  if (controls) {
    registry.add(
      ToolEntry(
        name: 'devtools.trace.start',
        title: 'Start trace recording',
        description:
            'Start recording only explicitly instrumented app trace events.',
        inputSchema: AiDebugSchema.object({
          'clear': AiDebugSchema.boolean(default_: false),
        }),
        annotations: _destructive,
        handler: (args) {
          tools.trace.start(clear: args['clear'] as bool? ?? false);
          return tools.trace.status();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.trace.stop',
        title: 'Stop trace recording',
        description:
            'Stop the shared trace recorder and close all open spans as cancelled.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _destructive,
        handler: (_) {
          tools.stopTrace();
          return tools.trace.status();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.trace.instant',
        title: 'Record trace instant',
        description:
            'Record a named instant while in-process tracing is enabled.',
        inputSchema: _traceEventSchema(),
        annotations: _control,
        handler: (args) {
          tools.trace.instant(
            args['name'] as String,
            category: args['category'] as String? ?? 'remote',
            arguments: _mapArg(args, 'arguments'),
          );
          return tools.trace.status();
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.trace.span_start',
        title: 'Start remote trace span',
        description:
            'Start a bounded named span and return an id for devtools.trace.span_finish.',
        inputSchema: _traceEventSchema(),
        annotations: _control,
        handler: (args) {
          final id = tools.startRemoteSpan(
            args['name'] as String,
            category: args['category'] as String? ?? 'remote',
            arguments: _mapArg(args, 'arguments'),
          );
          return {
            'recording': tools.trace.isRecording,
            'spanId': id,
            'openSpans': tools.trace.openSpanCount,
            'limits': _traceLimits,
          };
        },
      ),
    );
    registry.add(
      ToolEntry(
        name: 'devtools.trace.span_finish',
        title: 'Finish remote trace span',
        description: 'Finish one open remote span by id.',
        inputSchema: AiDebugSchema.object(
          {'span_id': AiDebugSchema.integer(min: 1), 'arguments': _mapSchema},
          required: ['span_id'],
        ),
        annotations: _control,
        handler: (args) {
          tools.finishRemoteSpan(
            args['span_id'] as int,
            arguments: _mapArg(args, 'arguments'),
          );
          return tools.trace.status();
        },
      ),
    );
  }

  registry.add(
    ToolEntry(
      name: 'devtools.trace.events',
      title: 'Read trace events',
      description:
          'Read the newest bounded, explicitly instrumented trace events.',
      inputSchema: _limitSchema(2000, 200),
      annotations: _readOnly,
      handler: (args) {
        final events = tools.trace.events(limit: args['limit'] as int? ?? 200);
        return {
          'source': 'ai_debug-in-process-trace',
          'scope': 'instrumented events only',
          'count': events.length,
          'capacity': tools.trace.capacity,
          'droppedEvents': tools.trace.droppedEvents,
          'events': [for (final event in events) event.toJson()],
          'limits': _traceLimits,
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'devtools.trace.export_chrome',
      title: 'Export Chrome trace',
      description:
          'Return a Chrome trace JSON object for bounded instrumented events.',
      inputSchema: _limitSchema(2000, 2000),
      annotations: _readOnly,
      handler: (args) =>
          tools.trace.exportChromeTrace(limit: args['limit'] as int? ?? 2000),
    ),
  );

  if (controls) {
    registry.add(
      ToolEntry(
        name: 'devtools.trace.clear',
        title: 'Clear trace events',
        description: 'Clear finished trace events and the dropped-event count.',
        inputSchema: AiDebugSchema.empty(),
        annotations: _destructive,
        handler: (_) {
          tools.trace.clear();
          return tools.trace.status();
        },
      ),
    );
  }

  return tools;
}

AiDebugSchema _limitSchema(int max, int defaultValue) => AiDebugSchema.object({
  'limit': AiDebugSchema.integer(min: 1, max: max, default_: defaultValue),
});

AiDebugSchema _treeSchema({bool includeStringLength = false}) =>
    AiDebugSchema.object({
      'max_nodes': AiDebugSchema.integer(min: 1, max: 10000, default_: 500),
      'max_depth': AiDebugSchema.integer(min: 0, max: 200, default_: 50),
      if (includeStringLength)
        'max_string_length': AiDebugSchema.integer(
          min: 1,
          max: 10000,
          default_: 200,
        ),
    });

AiDebugSchema _traceEventSchema() => AiDebugSchema.object(
  {
    'name': AiDebugSchema.string(minLength: 1, maxLength: 256),
    'category': AiDebugSchema.string(
      default_: 'remote',
      minLength: 1,
      maxLength: 256,
    ),
    'arguments': _mapSchema,
  },
  required: ['name'],
);

Map<String, Object?> _mapArg(Map<String, dynamic> args, String name) {
  final value = args[name];
  return value == null
      ? const <String, Object?>{}
      : Map<String, Object?>.from(value as Map);
}

const _resourceLimits = <String, Object?>{
  'rss': 'Whole-process resident memory; it is not Dart heap usage.',
  'cpu': 'CPU usage requires VM service, native, or host tooling.',
  'heap': 'Dart heap, allocations, and GC require VM service.',
  'native': 'GPU, thermal, battery, and native heap are not available here.',
};

const _frameLimits = <String, Object?>{
  'viewAttribution':
      'FrameTiming has no view id; multi-view frames cannot be separated.',
  'refreshRate':
      'The budget uses the implicit view display rate at callback time; multi-display frames may differ.',
  'combinedWork':
      'UI and raster threads are pipelined; combined time is not a missed-frame count.',
  'fps':
      'Observed frame rate includes every gap between the first and last sampled frame; use idle to distinguish a stopped app.',
  'mode':
      'Use profile mode for performance evidence; debug mode adds overhead.',
};

const _traceLimits = <String, Object?>{
  'vmTimeline':
      'Full Dart, engine, GC, and compiler events require VM service.',
  'isolates': 'Other isolates need their own recorder or explicit forwarding.',
  'timelineLaneId':
      'Chrome trace tid is a synthetic isolate lane, not an operating-system thread id.',
};

final _mapSchema = AiDebugSchema.object(const {}, additionalProperties: true);

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': false,
};

const _destructive = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': false,
};
