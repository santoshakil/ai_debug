import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../internal/level_codec.dart';
import '../registry.dart';

/// Register runtime-control tools: log level, app lifecycle, reassemble,
/// scheduling, system chrome.
void registerRuntimeTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'set_log_level',
    description:
        'Change the root Dart Logger level at runtime. Accepts trace|debug|info|warn|error|off|all.',
    inputSchema: AiDebugSchema.object(
      {
        'level': AiDebugSchema.string(
          enum_: ['trace', 'debug', 'info', 'warn', 'warning', 'error', 'severe', 'off', 'all', 'finest', 'fine'],
        ),
      },
      required: ['level'],
    ),
    handler: (args) async {
      final lvl = parseLoggingLevel(args['level'] as String);
      if (lvl == null) {
        return {'ok': false, 'error': 'unknown level: ${args['level']}'};
      }
      Logger.root.level = lvl;
      return {'ok': true, 'level': lvl.name};
    },
  ));

  registry.add(ToolEntry(
    name: 'get_log_level',
    description: 'Read the current root Logger level.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {
      'level': Logger.root.level.name,
      'value': Logger.root.level.value,
    },
  ));

  registry.add(ToolEntry(
    name: 'reassemble',
    description:
        'Call WidgetsBinding.reassembleApplication — equivalent to pulling down Flutter\'s dev-menu "reassemble" (partial hot-reload side effect).',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      await WidgetsBinding.instance.reassembleApplication();
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'performance_overlay',
    description:
        'Enable / disable Flutter\'s FPS performance overlay. (Effective at the next frame; apps must wrap their MaterialApp in the observer for full effect.)',
    inputSchema: AiDebugSchema.object({
      'enabled': AiDebugSchema.boolean(default_: true),
    }),
    handler: (args) async {
      final flag = args['enabled'] as bool? ?? true;
      WidgetsApp.showPerformanceOverlayOverride = flag;
      WidgetsBinding.instance.reassembleApplication();
      return {'ok': true, 'enabled': flag};
    },
  ));

  registry.add(ToolEntry(
    name: 'system_chrome_set',
    description:
        'Set SystemUiOverlayStyle (status-bar/nav-bar brightness + color) — useful for verifying UI chrome adapts to theme.',
    inputSchema: AiDebugSchema.object({
      'statusBarBrightness': AiDebugSchema.string(enum_: ['light', 'dark']),
      'navigationBarBrightness': AiDebugSchema.string(enum_: ['light', 'dark']),
    }),
    handler: (args) async {
      Brightness? map(String? s) => switch (s) {
            'light' => Brightness.light,
            'dark' => Brightness.dark,
            _ => null,
          };
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarIconBrightness: map(args['statusBarBrightness'] as String?),
        systemNavigationBarIconBrightness: map(args['navigationBarBrightness'] as String?),
      ));
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'set_preferred_orientations',
    description: 'Lock device orientations to a list (portrait-up, portrait-down, landscape-left, landscape-right, all).',
    inputSchema: AiDebugSchema.object({
      'orientations': AiDebugSchema.array(
        AiDebugSchema.string(
          enum_: ['portrait-up', 'portrait-down', 'landscape-left', 'landscape-right', 'all'],
        ),
      ),
    }),
    handler: (args) async {
      final list = (args['orientations'] as List?)?.cast<String>() ?? const ['all'];
      final out = <DeviceOrientation>[];
      for (final o in list) {
        switch (o) {
          case 'portrait-up':
            out.add(DeviceOrientation.portraitUp);
            break;
          case 'portrait-down':
            out.add(DeviceOrientation.portraitDown);
            break;
          case 'landscape-left':
            out.add(DeviceOrientation.landscapeLeft);
            break;
          case 'landscape-right':
            out.add(DeviceOrientation.landscapeRight);
            break;
          case 'all':
          default:
            out.addAll(DeviceOrientation.values);
        }
      }
      await SystemChrome.setPreferredOrientations(out.toSet().toList());
      return {'ok': true, 'orientations': list};
    },
  ));

  registry.add(ToolEntry(
    name: 'time_dilation_set',
    description:
        'Set Flutter\'s animation clock dilation (1.0 = normal, 10.0 = 10× slower — useful to inspect animation frames).',
    inputSchema: AiDebugSchema.object(
      {'factor': AiDebugSchema.number(min: 0.1, max: 100)},
      required: ['factor'],
    ),
    handler: (args) async {
      timeDilation = (args['factor'] as num).toDouble();
      return {'ok': true, 'factor': timeDilation};
    },
  ));

  registry.add(ToolEntry(
    name: 'schedule_frame',
    description:
        'Force Flutter to schedule a new frame — useful if the UI appears stuck and you want to verify it\'s responsive.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      WidgetsBinding.instance.scheduleFrame();
      return {'ok': true};
    },
  ));
}
