import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../registry.dart';

final _baseline = <String, bool>{};
final _owned = <String, bool>{};

void registerDiagnosticsTools(
  CommandRegistry registry, {
  required bool controls,
}) {
  registry.add(
    ToolEntry(
      name: 'devtools.focus',
      description: 'Current Flutter focus tree and primary focus.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'tree': _cut(FocusManager.instance.rootScope.toStringDeep(), 262144),
        'primaryFocus': FocusManager.instance.primaryFocus?.debugLabel,
        'scope': 'current Flutter engine',
      },
    ),
  );
  if (controls) {
    registry.add(
      ToolEntry(
        name: 'devtools.debug_flags',
        description: 'Read or set Flutter debug paint and profiling flags.',
        inputSchema: AiDebugSchema.object({
          'paintSize': AiDebugSchema.boolean(),
          'paintBaselines': AiDebugSchema.boolean(),
          'paintLayerBorders': AiDebugSchema.boolean(),
          'paintPointers': AiDebugSchema.boolean(),
          'repaintRainbow': AiDebugSchema.boolean(),
          'repaintTextRainbow': AiDebugSchema.boolean(),
          'profileBuilds': AiDebugSchema.boolean(),
          'profilePaints': AiDebugSchema.boolean(),
        }),
        annotations: _control,
        handler: (args) async {
          if (args['paintSize'] case final bool value) {
            _setFlag('paintSize', value);
          }
          if (args['paintBaselines'] case final bool value) {
            _setFlag('paintBaselines', value);
          }
          if (args['paintLayerBorders'] case final bool value) {
            _setFlag('paintLayerBorders', value);
          }
          if (args['paintPointers'] case final bool value) {
            _setFlag('paintPointers', value);
          }
          if (args['repaintRainbow'] case final bool value) {
            _setFlag('repaintRainbow', value);
          }
          if (args['repaintTextRainbow'] case final bool value) {
            _setFlag('repaintTextRainbow', value);
          }
          if (args['profileBuilds'] case final bool value) {
            _setFlag('profileBuilds', value);
          }
          if (args['profilePaints'] case final bool value) {
            _setFlag('profilePaints', value);
          }
          if (args.isNotEmpty) {
            await WidgetsBinding.instance.reassembleApplication();
          }
          return {
            'paintSize': debugPaintSizeEnabled,
            'paintBaselines': debugPaintBaselinesEnabled,
            'paintLayerBorders': debugPaintLayerBordersEnabled,
            'paintPointers': debugPaintPointersEnabled,
            'repaintRainbow': debugRepaintRainbowEnabled,
            'repaintTextRainbow': debugRepaintTextRainbowEnabled,
            'profileBuilds': debugProfileBuildsEnabled,
            'profilePaints': debugProfilePaintsEnabled,
          };
        },
      ),
    );
  }
}

bool disposeDiagnosticsTools() {
  var changed = false;
  for (final entry in _baseline.entries) {
    if (_readFlag(entry.key) == _owned[entry.key]) {
      _writeFlag(entry.key, entry.value);
      changed = true;
    }
  }
  _baseline.clear();
  _owned.clear();
  return changed;
}

void _setFlag(String name, bool value) {
  _baseline.putIfAbsent(name, () => _readFlag(name));
  _writeFlag(name, value);
  _owned[name] = value;
}

bool _readFlag(String name) => switch (name) {
  'paintSize' => debugPaintSizeEnabled,
  'paintBaselines' => debugPaintBaselinesEnabled,
  'paintLayerBorders' => debugPaintLayerBordersEnabled,
  'paintPointers' => debugPaintPointersEnabled,
  'repaintRainbow' => debugRepaintRainbowEnabled,
  'repaintTextRainbow' => debugRepaintTextRainbowEnabled,
  'profileBuilds' => debugProfileBuildsEnabled,
  'profilePaints' => debugProfilePaintsEnabled,
  _ => throw ArgumentError.value(name, 'name'),
};

void _writeFlag(String name, bool value) {
  switch (name) {
    case 'paintSize':
      debugPaintSizeEnabled = value;
    case 'paintBaselines':
      debugPaintBaselinesEnabled = value;
    case 'paintLayerBorders':
      debugPaintLayerBordersEnabled = value;
    case 'paintPointers':
      debugPaintPointersEnabled = value;
    case 'repaintRainbow':
      debugRepaintRainbowEnabled = value;
    case 'repaintTextRainbow':
      debugRepaintTextRainbowEnabled = value;
    case 'profileBuilds':
      debugProfileBuildsEnabled = value;
    case 'profilePaints':
      debugProfilePaintsEnabled = value;
    default:
      throw ArgumentError.value(name, 'name');
  }
}

String _cut(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': false,
};
