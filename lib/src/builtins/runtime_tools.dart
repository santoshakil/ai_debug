import 'package:flutter/widgets.dart';

import '../registry.dart';

var _baselineOverlay = false;
bool? _ownedOverlay;
var _capturedOverlay = false;

void registerRuntimeTools(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'runtime.reassemble',
      description: 'Reassemble the running Flutter application.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _control,
      handler: (_) async {
        await WidgetsBinding.instance.reassembleApplication();
        return {'ok': true};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'runtime.performance_overlay',
      description: 'Set Flutter performance overlay override.',
      inputSchema: AiDebugSchema.object(
        {'enabled': AiDebugSchema.boolean()},
        required: ['enabled'],
      ),
      annotations: _control,
      handler: (args) async {
        final enabled = args['enabled'] as bool;
        if (!_capturedOverlay) {
          _baselineOverlay = WidgetsApp.showPerformanceOverlayOverride;
          _capturedOverlay = true;
        }
        WidgetsApp.showPerformanceOverlayOverride = enabled;
        _ownedOverlay = enabled;
        await WidgetsBinding.instance.reassembleApplication();
        return {'enabled': enabled};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'runtime.schedule_frame',
      description: 'Schedule a Flutter frame.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _control,
      handler: (_) {
        WidgetsBinding.instance.scheduleFrame();
        return {'ok': true};
      },
    ),
  );
}

bool disposeRuntimeTools() {
  final baseline = _baselineOverlay;
  final owned = _ownedOverlay;
  _ownedOverlay = null;
  final captured = _capturedOverlay;
  _capturedOverlay = false;
  if (!captured || owned == null) return false;
  if (WidgetsApp.showPerformanceOverlayOverride != owned) return false;
  WidgetsApp.showPerformanceOverlayOverride = baseline;
  return true;
}

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': false,
};
