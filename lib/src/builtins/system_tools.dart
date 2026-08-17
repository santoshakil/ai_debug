import 'dart:io';
import 'dart:ui' as ui;

import '../registry.dart';

void registerSystemTools(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'device_info',
      description:
          'OS, Dart runtime, locale, accessibility, and implicit Flutter view data.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) {
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
            'numberOfProcessors': Platform.numberOfProcessors,
          },
          'dart': {'version': Platform.version},
          'locale': {
            'current': dispatcher.locale.toString(),
            'preferred': [
              for (final locale in dispatcher.locales) locale.toString(),
            ],
          },
          'brightness': dispatcher.platformBrightness.name,
          'accessibility': {
            'alwaysUse24HourFormat': dispatcher.alwaysUse24HourFormat,
            'accessibleNavigation':
                dispatcher.accessibilityFeatures.accessibleNavigation,
            'boldText': dispatcher.accessibilityFeatures.boldText,
            'disableAnimations':
                dispatcher.accessibilityFeatures.disableAnimations,
            'highContrast': dispatcher.accessibilityFeatures.highContrast,
            'invertColors': dispatcher.accessibilityFeatures.invertColors,
            'reduceMotion': dispatcher.accessibilityFeatures.reduceMotion,
          },
          'implicitView': view == null ? null : _view(view, true),
          'viewCount': dispatcher.views.length,
          'displayCount': dispatcher.displays.length,
          'scope': 'current Flutter engine',
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'displays',
      description: 'Displays and Flutter views visible to the current engine.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) {
        final dispatcher = ui.PlatformDispatcher.instance;
        final implicitId = dispatcher.implicitView?.viewId;
        final views = [
          for (final view in dispatcher.views)
            _view(view, view.viewId == implicitId),
        ];
        final displays = [
          for (final display in dispatcher.displays)
            {
              'id': display.id,
              'physicalSize': _size(display.size),
              'devicePixelRatio': display.devicePixelRatio,
              'logicalSize': _logicalSize(
                display.size,
                display.devicePixelRatio,
              ),
              'refreshRate': display.refreshRate,
            },
        ];
        final viewDisplayIds = views.map((view) => view['displayId']).toSet();
        return {
          'implicitViewId': implicitId,
          'viewCount': views.length,
          'displayCount': displays.length,
          'allKnownDisplaysHaveViews': displays.every(
            (display) => viewDisplayIds.contains(display['id']),
          ),
          'views': views,
          'displays': displays,
          'scope': 'current Flutter engine; other engines are not visible',
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'memory',
      description: 'Current and peak resident memory for the app process.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {
        'rssBytes': ProcessInfo.currentRss,
        'maxRssBytes': ProcessInfo.maxRss,
        'scope': 'whole app process; Dart heap and GC need VM service tools',
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'dart_version',
      description: 'Dart runtime version.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => {'version': Platform.version},
    ),
  );
}

Map<String, Object?> _view(ui.FlutterView view, bool implicit) {
  final ratio = view.devicePixelRatio;
  return {
    'viewId': view.viewId,
    'displayId': view.display.id,
    'isImplicit': implicit,
    'physicalSize': _size(view.physicalSize),
    'devicePixelRatio': ratio,
    'logicalSize': _logicalSize(view.physicalSize, ratio),
    'padding': {
      'top': view.padding.top / ratio,
      'bottom': view.padding.bottom / ratio,
      'left': view.padding.left / ratio,
      'right': view.padding.right / ratio,
    },
    'usableLogicalHeight':
        (view.physicalSize.height - view.padding.top - view.padding.bottom) /
        ratio,
    'refreshRate': view.display.refreshRate,
  };
}

Map<String, double> _size(ui.Size size) => {
  'width': size.width,
  'height': size.height,
};

Map<String, double> _logicalSize(ui.Size size, double ratio) => {
  'width': size.width / ratio,
  'height': size.height / ratio,
};

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};
