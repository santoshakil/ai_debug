import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../registry.dart';

void registerScreenshotTool(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'screenshot',
      description: 'Capture the current frame as PNG.',
      inputSchema: AiDebugSchema.object({
        'scale': AiDebugSchema.number(
          default_: 1.0,
          min: 0.25,
          max: 3.0,
          description: 'Output pixels per logical pixel.',
        ),
        'maxPixels': AiDebugSchema.integer(
          default_: 16000000,
          min: 10000,
          max: 64000000,
        ),
      }),
      annotations: const {'readOnlyHint': true, 'openWorldHint': false},
      handler: (args) async {
        final scale = (args['scale'] as num?)?.toDouble() ?? 1.0;
        final maxPixels = args['maxPixels'] as int? ?? 16000000;
        final bytes = await captureScreenshot(
          scale: scale,
          maxPixels: maxPixels,
        );
        if (bytes == null) {
          throw StateError('screenshot root is unavailable');
        }
        return AiDebugResult.binary(bytes, mime: 'image/png');
      },
    ),
  );
}

GlobalKey? _screenshotRoot;

GlobalKey? get screenshotRootKey => _screenshotRoot;

void setScreenshotRootKey(GlobalKey? key) {
  _screenshotRoot = key;
}

void clearScreenshotRootKey() => _screenshotRoot = null;

Future<Uint8List?> captureScreenshot({
  double scale = 1.0,
  int maxPixels = 16000000,
}) async {
  if (!scale.isFinite || scale <= 0 || maxPixels < 1) {
    throw ArgumentError('invalid screenshot limits');
  }
  final key = _screenshotRoot;
  if (key != null) {
    final ctx = key.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is RenderRepaintBoundary) {
      _checkPixels(ro.size.width, ro.size.height, scale, maxPixels);
      return _renderBoundaryToPng(ro, scale);
    }
  }

  if (kDebugMode || kProfileMode) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view != null) {
      final renderView = RendererBinding.instance.renderViews.firstWhere(
        (r) => r.flutterView == view,
        orElse: () => RendererBinding.instance.renderViews.first,
      );
      final layer = renderView.debugLayer;
      if (layer is OffsetLayer) {
        final physical = view.physicalSize;
        _checkPixels(
          physical.width,
          physical.height,
          scale / view.devicePixelRatio,
          maxPixels,
        );
        final image = await layer.toImage(
          Rect.fromLTWH(0, 0, physical.width, physical.height),
          pixelRatio: scale / view.devicePixelRatio,
        );
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          return bytes?.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }
    }
  }

  return null;
}

void _checkPixels(double width, double height, double scale, int maxPixels) {
  final pixels = width * height * scale * scale;
  if (!pixels.isFinite || pixels > maxPixels) {
    throw StateError('screenshot exceeds $maxPixels pixels');
  }
}

Future<Uint8List> _renderBoundaryToPng(
  RenderRepaintBoundary boundary,
  double pixelRatio,
) async {
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
