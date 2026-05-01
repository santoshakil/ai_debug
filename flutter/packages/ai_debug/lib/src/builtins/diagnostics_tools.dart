import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../registry.dart';

/// Register diagnostics tools: widget tree, render tree, debug paint flags,
/// test error injection, semantics dump.
void registerDiagnosticsTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'widget_tree',
    description:
        'Dump the current widget tree (Flutter\'s debugDumpApp output). Useful when navigating blind.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final buf = StringBuffer();
      final previous = debugPrint;
      debugPrint = (msg, {wrapWidth}) {
        if (msg != null) buf.writeln(msg);
      };
      try {
        WidgetsBinding.instance.rootElement?.debugVisitOnstageChildren((_) => true);
        debugDumpApp();
      } finally {
        debugPrint = previous;
      }
      return {'tree': buf.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'render_tree',
    description: 'Dump the render object tree (Flutter\'s debugDumpRenderTree output).',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final buf = StringBuffer();
      final previous = debugPrint;
      debugPrint = (msg, {wrapWidth}) {
        if (msg != null) buf.writeln(msg);
      };
      try {
        debugDumpRenderTree();
      } finally {
        debugPrint = previous;
      }
      return {'tree': buf.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'semantics_tree',
    description:
        'Dump the accessibility / semantics tree. Only populated when semantics is enabled (screen reader, driver tests).',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final buf = StringBuffer();
      final previous = debugPrint;
      debugPrint = (msg, {wrapWidth}) {
        if (msg != null) buf.writeln(msg);
      };
      try {
        debugDumpSemanticsTree();
      } finally {
        debugPrint = previous;
      }
      return {'tree': buf.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'layer_tree',
    description: 'Dump the compositor layer tree (debugDumpLayerTree).',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final buf = StringBuffer();
      final previous = debugPrint;
      debugPrint = (msg, {wrapWidth}) {
        if (msg != null) buf.writeln(msg);
      };
      try {
        debugDumpLayerTree();
      } finally {
        debugPrint = previous;
      }
      return {'tree': buf.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'focus_tree',
    description: 'Dump the current focus scope tree.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final buf = StringBuffer();
      final previous = debugPrint;
      debugPrint = (msg, {wrapWidth}) {
        if (msg != null) buf.writeln(msg);
      };
      try {
        debugDumpFocusTree();
      } finally {
        debugPrint = previous;
      }
      return {'tree': buf.toString()};
    },
  ));

  registry.add(ToolEntry(
    name: 'debug_flags_get',
    description: 'Read current Flutter debug-paint flags.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {
      'debugPaintSizeEnabled': debugPaintSizeEnabled,
      'debugPaintBaselinesEnabled': debugPaintBaselinesEnabled,
      'debugPaintLayerBordersEnabled': debugPaintLayerBordersEnabled,
      'debugPaintPointersEnabled': debugPaintPointersEnabled,
      'debugRepaintRainbowEnabled': debugRepaintRainbowEnabled,
      'debugRepaintTextRainbowEnabled': debugRepaintTextRainbowEnabled,
      'debugProfileBuildsEnabled': debugProfileBuildsEnabled,
      'debugProfilePaintsEnabled': debugProfilePaintsEnabled,
      'debugDisableClipLayers': debugDisableClipLayers,
      'debugDisableOpacityLayers': debugDisableOpacityLayers,
      'debugDisablePhysicalShapeLayers': debugDisablePhysicalShapeLayers,
      'debugDisableShadows': debugDisableShadows,
    },
  ));

  registry.add(ToolEntry(
    name: 'debug_flags_set',
    description: 'Toggle Flutter debug-paint flags at runtime.',
    inputSchema: AiDebugSchema.object({
      'paintSize': AiDebugSchema.boolean(description: 'Outline every widget'),
      'paintBaselines': AiDebugSchema.boolean(),
      'paintLayerBorders': AiDebugSchema.boolean(),
      'paintPointers': AiDebugSchema.boolean(),
      'repaintRainbow': AiDebugSchema.boolean(description: 'Cycle colors on every repaint'),
      'repaintTextRainbow': AiDebugSchema.boolean(),
      'profileBuilds': AiDebugSchema.boolean(),
      'profilePaints': AiDebugSchema.boolean(),
    }),
    handler: (args) async {
      if (args['paintSize'] is bool) debugPaintSizeEnabled = args['paintSize'] as bool;
      if (args['paintBaselines'] is bool) debugPaintBaselinesEnabled = args['paintBaselines'] as bool;
      if (args['paintLayerBorders'] is bool) debugPaintLayerBordersEnabled = args['paintLayerBorders'] as bool;
      if (args['paintPointers'] is bool) debugPaintPointersEnabled = args['paintPointers'] as bool;
      if (args['repaintRainbow'] is bool) debugRepaintRainbowEnabled = args['repaintRainbow'] as bool;
      if (args['repaintTextRainbow'] is bool) debugRepaintTextRainbowEnabled = args['repaintTextRainbow'] as bool;
      if (args['profileBuilds'] is bool) debugProfileBuildsEnabled = args['profileBuilds'] as bool;
      if (args['profilePaints'] is bool) debugProfilePaintsEnabled = args['profilePaints'] as bool;
      // Trigger a global repaint so the change is visible immediately.
      WidgetsBinding.instance.reassembleApplication();
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'trigger_error',
    description:
        'Throw a test exception or FlutterError to verify error handlers. Use sparingly.',
    inputSchema: AiDebugSchema.object({
      'message': AiDebugSchema.string(default_: 'ai_debug: test error'),
      'kind': AiDebugSchema.string(
        default_: 'exception',
        enum_: ['exception', 'flutter_error', 'assert', 'unhandled'],
      ),
    }),
    handler: (args) async {
      final msg = (args['message'] as String?) ?? 'ai_debug: test error';
      final kind = (args['kind'] as String?) ?? 'exception';
      switch (kind) {
        case 'flutter_error':
          FlutterError.reportError(FlutterErrorDetails(exception: Exception(msg)));
          break;
        case 'assert':
          assert(false, msg);
          break;
        case 'unhandled':
          Future<void>.error(StateError(msg));
          break;
        case 'exception':
        default:
          throw Exception(msg);
      }
      return {'ok': true};
    },
  ));
}
