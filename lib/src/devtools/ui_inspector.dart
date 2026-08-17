import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class UiInspector {
  const UiInspector();

  Map<String, Object?> widgetTree({
    int maxNodes = 500,
    int maxDepth = 50,
    int maxStringLength = 200,
  }) {
    _validateLimits(maxNodes, maxDepth, maxStringLength);
    final nodes = <Map<String, Object?>>[];
    var truncatedByNodeLimit = false;
    var truncatedByDepth = false;
    var nextId = 0;

    void visit(Element element, String? parentId, int depth, bool onstage) {
      if (nodes.length >= maxNodes) {
        truncatedByNodeLimit = true;
        return;
      }
      final id = 'element-${nextId++}';
      final widget = element.widget;
      final currentOnstage =
          onstage && !(widget is Offstage && widget.offstage);
      final renderObject = element is RenderObjectElement
          ? element.renderObject
          : null;
      nodes.add({
        'id': id,
        'parentId': ?parentId,
        'depth': depth,
        'widgetType': widget.runtimeType.toString(),
        'elementType': element.runtimeType.toString(),
        if (widget.key != null)
          'key': _cut(widget.key.toString(), maxStringLength),
        if (element case StatefulElement(:final state))
          'stateType': state.runtimeType.toString(),
        'mounted': element.mounted,
        'onstageByOffstageAncestors': currentOnstage,
        if (renderObject != null) ...{
          'renderObjectType': renderObject.runtimeType.toString(),
          'renderAttached': renderObject.attached,
          'globalBounds': ?_globalBounds(renderObject),
        },
      });
      if (depth >= maxDepth) {
        element.visitChildren((_) => truncatedByDepth = true);
        return;
      }
      element.visitChildren(
        (child) => visit(child, id, depth + 1, currentOnstage),
      );
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root, null, 0, true);
    return {
      'source': 'flutter-element-tree',
      'scope': 'current Flutter engine',
      'mode': _buildMode,
      'coordinateSpace': 'global logical pixels',
      'nodeCount': nodes.length,
      'truncated': truncatedByNodeLimit || truncatedByDepth,
      'truncatedByNodeLimit': truncatedByNodeLimit,
      'truncatedByDepth': truncatedByDepth,
      'nodes': nodes,
      'limits': const {
        'state':
            'Only State type and mounted widget data are visible; private fields are not inspected.',
        'visibility':
            'Onstage is inferred from Offstage ancestors, not physical occlusion.',
        'content':
            'Keys and widget types can contain app data; treat this snapshot as sensitive.',
      },
    };
  }

  Map<String, Object?> renderTree({int maxNodes = 500, int maxDepth = 50}) {
    _validateLimits(maxNodes, maxDepth, 1);
    final nodes = <Map<String, Object?>>[];
    final roots = <Map<String, Object?>>[];
    var truncatedByNodeLimit = false;
    var truncatedByDepth = false;
    var nextId = 0;

    void visit(RenderObject renderObject, String? parentId, int depth) {
      if (nodes.length >= maxNodes) {
        truncatedByNodeLimit = true;
        return;
      }
      final id = 'render-${nextId++}';
      nodes.add({
        'id': id,
        'parentId': ?parentId,
        'depth': depth,
        'renderObjectType': renderObject.runtimeType.toString(),
        'attached': renderObject.attached,
        'needsCompositing': renderObject.needsCompositing,
        'isRepaintBoundary': renderObject.isRepaintBoundary,
        'paintBounds': _rect(renderObject.paintBounds),
        'semanticBounds': _rect(renderObject.semanticBounds),
        if (renderObject.parentData != null)
          'parentDataType': renderObject.parentData.runtimeType.toString(),
        'globalBounds': ?_globalBounds(renderObject),
      });
      if (depth >= maxDepth) {
        renderObject.visitChildren((_) => truncatedByDepth = true);
        return;
      }
      renderObject.visitChildren((child) => visit(child, id, depth + 1));
    }

    for (final renderView in RendererBinding.instance.renderViews) {
      if (nodes.length >= maxNodes) {
        truncatedByNodeLimit = true;
        break;
      }
      final rootId = 'render-$nextId';
      roots.add({
        'viewId': renderView.flutterView.viewId,
        'displayId': renderView.flutterView.display.id,
        'rootId': rootId,
      });
      visit(renderView, null, 0);
    }
    return {
      'source': 'flutter-render-tree',
      'scope': 'render views owned by the current Flutter engine',
      'mode': _buildMode,
      'coordinateSpace': 'global logical pixels where available',
      'rootCount': roots.length,
      'nodeCount': nodes.length,
      'truncated': truncatedByNodeLimit || truncatedByDepth,
      'truncatedByNodeLimit': truncatedByNodeLimit,
      'truncatedByDepth': truncatedByDepth,
      'roots': roots,
      'nodes': nodes,
      'limits': const {
        'layers': 'The layer tree is exposed separately in debug builds.',
        'dirtyState': 'Private layout and paint queues are not inspected.',
      },
    };
  }

  Map<String, Object?> layerTree({int maxNodes = 500, int maxDepth = 50}) {
    _validateLimits(maxNodes, maxDepth, 1);
    final nodes = <Map<String, Object?>>[];
    final roots = <Map<String, Object?>>[];
    var truncatedByNodeLimit = false;
    var truncatedByDepth = false;
    var nextId = 0;

    void visit(Layer layer, String? parentId, int depth) {
      if (nodes.length >= maxNodes) {
        truncatedByNodeLimit = true;
        return;
      }
      final id = 'layer-${nextId++}';
      final clip = layer.describeClipBounds();
      nodes.add({
        'id': id,
        'parentId': ?parentId,
        'depth': depth,
        'layerType': layer.runtimeType.toString(),
        'attached': layer.attached,
        'hasCompositionCallbacks': layer.subtreeHasCompositionCallbacks,
        if (clip != null) 'clipBounds': _rect(clip),
      });
      if (layer is! ContainerLayer) return;
      if (depth >= maxDepth) {
        if (layer.hasChildren) truncatedByDepth = true;
        return;
      }
      var child = layer.firstChild;
      while (child != null) {
        visit(child, id, depth + 1);
        child = child.nextSibling;
      }
    }

    for (final renderView in RendererBinding.instance.renderViews) {
      final layer = renderView.debugLayer;
      final root = <String, Object?>{
        'viewId': renderView.flutterView.viewId,
        'displayId': renderView.flutterView.display.id,
        'available': layer != null,
      };
      if (layer != null && nodes.length < maxNodes) {
        root['rootId'] = 'layer-$nextId';
        visit(layer, null, 0);
      } else if (layer != null) {
        truncatedByNodeLimit = true;
      }
      roots.add(root);
    }
    return {
      'source': 'flutter-layer-tree',
      'scope': 'debug layers for render views owned by this Flutter engine',
      'mode': _buildMode,
      'rootCount': roots.length,
      'nodeCount': nodes.length,
      'truncated': truncatedByNodeLimit || truncatedByDepth,
      'truncatedByNodeLimit': truncatedByNodeLimit,
      'truncatedByDepth': truncatedByDepth,
      'roots': roots,
      'nodes': nodes,
      'limits': const {
        'mode':
            'Flutter exposes RenderObject.debugLayer only in assert-enabled builds.',
        'engine': 'Private engine-layer and GPU details are not available.',
      },
    };
  }

  Future<Map<String, Object?>> semanticsTree({
    int maxNodes = 500,
    int maxDepth = 50,
    int maxStringLength = 200,
    Duration settleTimeout = const Duration(seconds: 1),
  }) async {
    _validateLimits(maxNodes, maxDepth, maxStringLength);
    if (settleTimeout <= Duration.zero) {
      throw ArgumentError.value(
        settleTimeout,
        'settleTimeout',
        'must be positive',
      );
    }
    final handle = SemanticsBinding.instance.ensureSemantics();
    var settleTimedOut = false;
    final scheduler = SchedulerBinding.instance;
    final framesEnabled = scheduler.framesEnabled;
    try {
      if (framesEnabled) {
        scheduler.scheduleFrame();
        try {
          await scheduler.endOfFrame.timeout(settleTimeout);
        } on TimeoutException {
          settleTimedOut = true;
        }
      }
      final nodes = <Map<String, Object?>>[];
      final roots = <Map<String, Object?>>[];
      var truncatedByNodeLimit = false;
      var truncatedByDepth = false;

      void visit(
        SemanticsNode node,
        String id,
        String? parentId,
        int depth,
        int viewId,
        double devicePixelRatio,
        Matrix4 parentTransform,
      ) {
        if (nodes.length >= maxNodes) {
          truncatedByNodeLimit = true;
          return;
        }
        final data = node.getSemanticsData();
        final flags = data.flagsCollection;
        final redactValue = flags.isTextField || flags.isObscured;
        final transform = Matrix4.copy(parentTransform);
        final nodeTransform = node.transform;
        if (nodeTransform != null) transform.multiply(nodeTransform);
        final physicalRect = MatrixUtils.transformRect(transform, data.rect);
        final logicalRect = _toLogicalRect(physicalRect, devicePixelRatio);
        nodes.add({
          'id': id,
          'parentId': ?parentId,
          'depth': depth,
          'viewId': viewId,
          'semanticsNodeId': node.id,
          'localRect': _rect(data.rect),
          'logicalRect': _rect(logicalRect),
          'physicalRect': _rect(physicalRect),
          'label': _cut(data.label, maxStringLength),
          if (!redactValue) 'value': _cut(data.value, maxStringLength),
          'valueRedacted': redactValue && data.value.isNotEmpty,
          'hint': _cut(data.hint, maxStringLength),
          'tooltip': _cut(data.tooltip, maxStringLength),
          'actions': [
            for (final action in SemanticsAction.values)
              if (data.hasAction(action)) action.name,
          ],
          'flags': flags.toStrings(),
          'isMergedIntoParent': node.isMergedIntoParent,
          'mergesDescendants': node.mergeAllDescendantsIntoThisNode,
          if (data.scrollIndex != null) 'scrollIndex': data.scrollIndex,
          if (data.scrollChildCount != null)
            'scrollChildCount': data.scrollChildCount,
          if (data.scrollPosition != null)
            'scrollPosition': _finite(data.scrollPosition!),
          if (data.scrollExtentMin != null)
            'scrollExtentMin': _finite(data.scrollExtentMin!),
          if (data.scrollExtentMax != null)
            'scrollExtentMax': _finite(data.scrollExtentMax!),
        });
        if (depth >= maxDepth) {
          node.visitChildren((_) {
            truncatedByDepth = true;
            return false;
          });
          return;
        }
        node.visitChildren((child) {
          visit(
            child,
            'semantics-$viewId-${child.id}',
            id,
            depth + 1,
            viewId,
            devicePixelRatio,
            transform,
          );
          return nodes.length < maxNodes;
        });
      }

      for (final renderView in RendererBinding.instance.renderViews) {
        if (nodes.length >= maxNodes) {
          truncatedByNodeLimit = true;
          break;
        }
        final view = renderView.flutterView;
        final viewId = view.viewId;
        final root = renderView.owner?.semanticsOwner?.rootSemanticsNode;
        if (root == null) continue;
        final id = 'semantics-$viewId-${root.id}';
        final dpr = _validRatio(view.devicePixelRatio);
        roots.add({
          'viewId': viewId,
          'displayId': view.display.id,
          'rootId': id,
          'devicePixelRatio': dpr,
          'physicalSize': _size(view.physicalSize),
          'logicalSize': _size(view.physicalSize / dpr),
        });
        visit(root, id, null, 0, viewId, dpr, Matrix4.identity());
      }
      return {
        'source': 'flutter-semantics-tree',
        'scope': 'render views owned by the current Flutter engine',
        'mode': _buildMode,
        'semanticsForcedForSnapshot': true,
        'framesEnabledAtSnapshot': framesEnabled,
        'settleTimedOut': settleTimedOut,
        'coordinateSpaces': const {
          'localRect': 'parent semantics-node coordinates',
          'logicalRect': 'view logical pixels',
          'physicalRect': 'view physical pixels',
        },
        'rootCount': roots.length,
        'nodeCount': nodes.length,
        'truncated': truncatedByNodeLimit || truncatedByDepth,
        'truncatedByNodeLimit': truncatedByNodeLimit,
        'truncatedByDepth': truncatedByDepth,
        'roots': roots,
        'nodes': nodes,
        'limits': const {
          'content':
              'Labels, values, hints, and tooltips may contain sensitive app data.',
          'platform':
              'This is Flutter semantics, not the final native accessibility tree.',
          'settling':
              'Paused apps cannot produce a settling frame; the last semantics tree is returned.',
        },
      };
    } finally {
      handle.dispose();
    }
  }
}

String get _buildMode => kReleaseMode
    ? 'release'
    : kProfileMode
    ? 'profile'
    : 'debug';

Map<String, Object?>? _globalBounds(RenderObject renderObject) {
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  final bounds = MatrixUtils.transformRect(
    renderObject.getTransformTo(null),
    Offset.zero & renderObject.size,
  );
  if (!bounds.left.isFinite ||
      !bounds.top.isFinite ||
      !bounds.width.isFinite ||
      !bounds.height.isFinite) {
    return null;
  }
  return _rect(bounds);
}

Map<String, Object?> _rect(Rect value) => {
  'left': _finite(value.left),
  'top': _finite(value.top),
  'width': _finite(value.width),
  'height': _finite(value.height),
};

Map<String, Object?> _size(Size value) => {
  'width': _finite(value.width),
  'height': _finite(value.height),
};

Rect _toLogicalRect(Rect physical, double devicePixelRatio) => Rect.fromLTRB(
  physical.left / devicePixelRatio,
  physical.top / devicePixelRatio,
  physical.right / devicePixelRatio,
  physical.bottom / devicePixelRatio,
);

double? _finite(double value) => value.isFinite ? value : null;

double _validRatio(double value) => value.isFinite && value > 0 ? value : 1;

String _cut(String value, int maxLength) =>
    value.length <= maxLength ? value : '${value.substring(0, maxLength - 1)}…';

void _validateLimits(int maxNodes, int maxDepth, int maxStringLength) {
  if (maxNodes < 1 || maxNodes > 10000) {
    throw RangeError.range(maxNodes, 1, 10000, 'maxNodes');
  }
  if (maxDepth < 0 || maxDepth > 200) {
    throw RangeError.range(maxDepth, 0, 200, 'maxDepth');
  }
  if (maxStringLength < 1 || maxStringLength > 10000) {
    throw RangeError.range(maxStringLength, 1, 10000, 'maxStringLength');
  }
}
