import 'dart:io';
import 'dart:ui' as ui;

import '../registry.dart';

/// Register system-level built-in tools: device info, memory, versions.
void registerSystemTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'device_info',
    description:
        'OS, platform, screen size, locale, brightness, and runtime info about the Flutter environment.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final dispatcher = ui.PlatformDispatcher.instance;
      final view = dispatcher.implicitView;
      return {
        'platform': {
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'isAndroid': Platform.isAndroid,
          'isIOS': Platform.isIOS,
          'isMacOS': Platform.isMacOS,
          'isLinux': Platform.isLinux,
          'isWindows': Platform.isWindows,
          'isFuchsia': Platform.isFuchsia,
          'localHostname': Platform.localHostname,
          'numberOfProcessors': Platform.numberOfProcessors,
          'pathSeparator': Platform.pathSeparator,
        },
        'dart': {
          'version': Platform.version,
          'executable': Platform.executable,
        },
        'locale': {
          'languageCode': dispatcher.locale.languageCode,
          'countryCode': dispatcher.locale.countryCode,
          'scriptCode': dispatcher.locale.scriptCode,
          'toString': dispatcher.locale.toString(),
          'locales': dispatcher.locales.map((l) => l.toString()).toList(),
        },
        'view': view == null
            ? null
            : {
                'physicalSize': {
                  'width': view.physicalSize.width,
                  'height': view.physicalSize.height,
                },
                'devicePixelRatio': view.devicePixelRatio,
                'logicalSize': {
                  'width': view.physicalSize.width / view.devicePixelRatio,
                  'height': view.physicalSize.height / view.devicePixelRatio,
                },
                'padding': {
                  'top': view.padding.top,
                  'bottom': view.padding.bottom,
                  'left': view.padding.left,
                  'right': view.padding.right,
                },
              },
        'brightness': dispatcher.platformBrightness.name,
        'accessibility': {
          'alwaysUse24HourFormat': dispatcher.alwaysUse24HourFormat,
          'accessibilityFeatures': {
            'accessibleNavigation': dispatcher.accessibilityFeatures.accessibleNavigation,
            'boldText': dispatcher.accessibilityFeatures.boldText,
            'disableAnimations': dispatcher.accessibilityFeatures.disableAnimations,
            'highContrast': dispatcher.accessibilityFeatures.highContrast,
            'invertColors': dispatcher.accessibilityFeatures.invertColors,
            'reduceMotion': dispatcher.accessibilityFeatures.reduceMotion,
          },
        },
        'env': {
          'numberOfLocales': dispatcher.locales.length,
        },
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'memory',
    description: 'Current process memory usage (RSS) and Dart VM stats.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      return {
        'rssBytes': ProcessInfo.currentRss,
        'maxRssBytes': ProcessInfo.maxRss,
        'rssMiB': (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1),
        'maxRssMiB': (ProcessInfo.maxRss / (1024 * 1024)).toStringAsFixed(1),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'dart_version',
    description: 'Dart SDK / runtime version string.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async => {'version': Platform.version},
  ));

  registry.add(ToolEntry(
    name: 'env_vars',
    description: 'Process environment variables. Use filter to narrow.',
    inputSchema: AiDebugSchema.object({
      'filter': AiDebugSchema.string(
        description: 'Substring match on variable name (case-insensitive).',
      ),
    }),
    handler: (args) async {
      final filter = (args['filter'] as String?)?.toLowerCase();
      final entries = Platform.environment.entries;
      final matched = filter == null || filter.isEmpty
          ? entries.toList()
          : entries.where((e) => e.key.toLowerCase().contains(filter)).toList();
      return {
        'count': matched.length,
        'vars': {for (final e in matched) e.key: e.value},
      };
    },
  ));
}
