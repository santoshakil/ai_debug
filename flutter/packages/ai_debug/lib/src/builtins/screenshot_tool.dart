import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../registry.dart';

/// Register the `screenshot` tool — returns a PNG of the current frame.
///
/// Implementation:
///   1. If the app registered a [GlobalKey<RepaintBoundaryState>] or generic
///      key via [setScreenshotRoot], use its RenderRepaintBoundary.toImage().
///   2. Otherwise, fall back to the root layer (debugLayer) — debug-mode only.
///
/// In release mode without [setScreenshotRoot] the tool returns an error
/// explaining how to enable screenshots.
void registerScreenshotTool(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'screenshot',
    description: 'Capture the current frame as PNG. Returns base64-encoded image bytes.',
    inputSchema: AiDebugSchema.object({
      'pixelRatio': AiDebugSchema.number(
        default_: 1.0,
        min: 0.25,
        max: 3.0,
        description: 'Pixel ratio for the output image (1.0 = logical pixels).',
      ),
    }),
    handler: (args) async {
      final pixelRatio = (args['pixelRatio'] as num?)?.toDouble() ?? 1.0;
      final bytes = await captureScreenshot(pixelRatio: pixelRatio);
      if (bytes == null) {
        return AiDebugResult.json({
          'ok': false,
          'error':
              'Screenshot unavailable. Call AiDebug.setScreenshotRoot(key) once '
              'at startup, where `key` wraps your app with a RepaintBoundary, '
              'or use a debug build.',
        });
      }
      return AiDebugResult.binary(bytes, mime: 'image/png');
    },
  ));
}

GlobalKey? _screenshotRoot;

/// Expose the `RepaintBoundary` that wraps the app. Call once at startup.
void setScreenshotRootKey(GlobalKey? key) {
  _screenshotRoot = key;
}

Future<Uint8List?> captureScreenshot({double pixelRatio = 1.0}) async {
  // Option 1 — explicit boundary set by the app.
  final key = _screenshotRoot;
  if (key != null) {
    final ctx = key.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is RenderRepaintBoundary) {
      return _renderBoundaryToPng(ro, pixelRatio);
    }
  }

  // Option 2 — root renderView layer (debug-mode only, `debugLayer` is off in release).
  if (kDebugMode || kProfileMode) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view != null) {
      final renderView = RendererBinding.instance.renderViews.firstWhere(
        (r) => r.flutterView == view,
        orElse: () => RendererBinding.instance.renderViews.first,
      );
      final layer = renderView.debugLayer;
      if (layer is OffsetLayer) {
        final size = renderView.size;
        final image = await layer.toImage(
          Rect.fromLTWH(0, 0, size.width, size.height),
          pixelRatio: pixelRatio,
        );
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes?.buffer.asUint8List();
      }
    }
  }

  return null;
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
