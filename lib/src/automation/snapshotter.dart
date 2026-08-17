import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'models.dart';

class UiSnapshotter {
  UiSnapshotter(this.config);

  final UiAutomationConfig config;
  var _nextId = 1;

  Future<UiSnapshot> snapshot({int? maxNodes, int? maxStringLength}) async {
    return inspect(
      (inspection) => inspection.snapshot,
      maxNodes: maxNodes,
      maxStringLength: maxStringLength,
    );
  }

  Future<T> inspect<T>(
    FutureOr<T> Function(UiInspection inspection) read, {
    int? maxNodes,
    int? maxStringLength,
  }) async {
    if (!config.enabled) {
      throw const UiAutomationError(
        'capability_disabled',
        'UI automation is disabled',
      );
    }
    final nodeLimit = _bounded(
      maxNodes ?? config.limits.maxNodes,
      1,
      config.limits.maxNodes,
      'max_nodes',
    );
    final stringLimit = _bounded(
      maxStringLength ?? config.limits.maxStringLength,
      1,
      config.limits.maxStringLength,
      'max_string_length',
    );

    final handle = SemanticsBinding.instance.ensureSemantics();
    try {
      await _waitForFrame();
      final inspection = _scan(nodeLimit, stringLimit);
      return await read(inspection);
    } finally {
      handle.dispose();
    }
  }

  Future<void> _waitForFrame() async {
    final scheduler = SchedulerBinding.instance;
    if (!scheduler.framesEnabled) return;
    try {
      await scheduler.endOfFrame.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      throw const UiAutomationError(
        'frame_timeout',
        'Flutter did not finish a frame within 2 seconds',
      );
    }
  }

  UiInspection _scan(int nodeLimit, int stringLimit) {
    final views = <UiViewSnapshot>[];
    final nodes = <UiNode>[];
    final handles = <String, UiNodeHandle>{};
    var truncated = false;
    var visited = 0;

    for (final renderView in RendererBinding.instance.renderViews) {
      final flutterView = renderView.flutterView;
      final dpr = flutterView.devicePixelRatio;
      final physicalSize = flutterView.physicalSize;
      final logicalSize = physicalSize / dpr;
      views.add(
        UiViewSnapshot(
          viewId: flutterView.viewId,
          devicePixelRatio: dpr,
          logicalWidth: logicalSize.width,
          logicalHeight: logicalSize.height,
          physicalWidth: physicalSize.width,
          physicalHeight: physicalSize.height,
        ),
      );

      final owner = renderView.owner?.semanticsOwner;
      final root = owner?.rootSemanticsNode;
      if (owner == null || root == null) continue;
      final viewBounds = ui.Offset.zero & physicalSize;

      void visit(
        SemanticsNode semanticNode,
        Matrix4 parentTransform,
        int? exposedParentId,
      ) {
        if (visited >= nodeLimit) {
          truncated = true;
          return;
        }
        visited++;
        final transform = Matrix4.copy(parentTransform);
        final nodeTransform = semanticNode.transform;
        if (nodeTransform != null) transform.multiply(nodeTransform);
        final physicalRect = MatrixUtils.transformRect(
          transform,
          semanticNode.rect,
        );
        final logicalRect = ui.Rect.fromLTRB(
          physicalRect.left / dpr,
          physicalRect.top / dpr,
          physicalRect.right / dpr,
          physicalRect.bottom / dpr,
        );
        final data = semanticNode.getSemanticsData();
        final flags = data.flagsCollection;
        final exposed = !semanticNode.isMergedIntoParent;
        var parentId = exposedParentId;

        if (exposed) {
          final textField = flags.isTextField;
          final obscured = flags.isObscured;
          final redactValue =
              obscured || (textField && !config.includeTextFieldValues);
          final actions = <String>{
            for (final entry in uiActionNames.entries)
              if (data.hasAction(entry.value)) entry.key,
          };
          final visible =
              !flags.isHidden &&
              !semanticNode.isInvisible &&
              _finiteRect(physicalRect) &&
              physicalRect.overlaps(viewBounds);
          if (visible) {
            final node = UiNode(
              id: semanticNode.id,
              viewId: flutterView.viewId,
              parentId: exposedParentId,
              identifier: _text(data.identifier, stringLimit),
              label: _text(data.label, stringLimit),
              value: redactValue ? null : _text(data.value, stringLimit),
              valueRedacted: redactValue && data.value.isNotEmpty,
              hint: _text(data.hint, stringLimit),
              tooltip: _text(data.tooltip, stringLimit),
              logicalRect: UiRect.fromRect(logicalRect),
              physicalRect: UiRect.fromRect(physicalRect),
              visible: true,
              enabled: flags.isEnabled.toBoolOrNull(),
              focused: flags.isFocused.toBoolOrNull() ?? false,
              textField: textField,
              readOnly: flags.isReadOnly,
              obscured: obscured,
              selected: flags.isSelected.toBoolOrNull(),
              checked: switch (flags.isChecked) {
                ui.CheckedState.none => null,
                ui.CheckedState.isTrue => true,
                ui.CheckedState.isFalse => false,
                ui.CheckedState.mixed => 'mixed',
              },
              toggled: flags.isToggled.toBoolOrNull(),
              expanded: flags.isExpanded.toBoolOrNull(),
              actions: actions,
              scrollPosition: data.scrollPosition,
              scrollExtentMin: data.scrollExtentMin,
              scrollExtentMax: data.scrollExtentMax,
            );
            nodes.add(node);
            handles['${node.viewId}:${node.id}'] = UiNodeHandle(
              node: node,
              semanticsNode: semanticNode,
              owner: owner,
            );
            parentId = node.id;
          }
        }

        final children = <SemanticsNode>[];
        semanticNode.visitChildren((child) {
          children.add(child);
          return true;
        });
        for (final child in children) {
          if (visited >= nodeLimit) {
            truncated = true;
            return;
          }
          visit(child, transform, parentId);
        }
      }

      visit(root, Matrix4.identity(), null);
      if (truncated) break;
    }

    return UiInspection(
      UiSnapshot(
        id: _nextId++,
        createdAt: DateTime.now(),
        views: List.unmodifiable(views),
        nodes: List.unmodifiable(nodes),
        truncated: truncated,
      ),
      Map.unmodifiable(handles),
    );
  }
}

int _bounded(int value, int min, int max, String name) {
  if (value < min || value > max) {
    throw UiAutomationError(
      'invalid_argument',
      '$name must be between $min and $max',
    );
  }
  return value;
}

bool _finiteRect(ui.Rect rect) =>
    rect.left.isFinite &&
    rect.top.isFinite &&
    rect.right.isFinite &&
    rect.bottom.isFinite &&
    !rect.isEmpty;

String? _text(String value, int maxLength) {
  final text = value.trim();
  if (text.isEmpty) return null;
  if (text.length <= maxLength) return text;
  return '${text.substring(0, maxLength - 1)}…';
}
