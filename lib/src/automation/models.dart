import 'dart:ui' as ui;

import 'package:flutter/semantics.dart';

const uiActionNames = <String, ui.SemanticsAction>{
  'tap': ui.SemanticsAction.tap,
  'longPress': ui.SemanticsAction.longPress,
  'focus': ui.SemanticsAction.focus,
  'setText': ui.SemanticsAction.setText,
  'setSelection': ui.SemanticsAction.setSelection,
  'scrollUp': ui.SemanticsAction.scrollUp,
  'scrollDown': ui.SemanticsAction.scrollDown,
  'scrollLeft': ui.SemanticsAction.scrollLeft,
  'scrollRight': ui.SemanticsAction.scrollRight,
  'increase': ui.SemanticsAction.increase,
  'decrease': ui.SemanticsAction.decrease,
  'dismiss': ui.SemanticsAction.dismiss,
  'expand': ui.SemanticsAction.expand,
  'collapse': ui.SemanticsAction.collapse,
  'showOnScreen': ui.SemanticsAction.showOnScreen,
};

class UiAutomationLimits {
  const UiAutomationLimits({
    this.maxNodes = 1000,
    this.maxStringLength = 200,
    this.maxWait = const Duration(seconds: 30),
    this.maxGesture = const Duration(seconds: 5),
    this.maxRunSteps = 40,
    this.maxScrolls = 30,
  });

  final int maxNodes;
  final int maxStringLength;
  final Duration maxWait;
  final Duration maxGesture;
  final int maxRunSteps;
  final int maxScrolls;

  bool sameAs(UiAutomationLimits other) =>
      maxNodes == other.maxNodes &&
      maxStringLength == other.maxStringLength &&
      maxWait == other.maxWait &&
      maxGesture == other.maxGesture &&
      maxRunSteps == other.maxRunSteps &&
      maxScrolls == other.maxScrolls;

  void validate() {
    if (maxNodes < 1 ||
        maxNodes > 10000 ||
        maxStringLength < 1 ||
        maxStringLength > 10000 ||
        maxWait < Duration.zero ||
        maxWait > const Duration(minutes: 5) ||
        maxGesture < const Duration(milliseconds: 120) ||
        maxGesture > const Duration(seconds: 10) ||
        maxRunSteps < 1 ||
        maxRunSteps > 100 ||
        maxScrolls < 1 ||
        maxScrolls > 100) {
      throw ArgumentError('invalid UI automation limits');
    }
  }
}

class UiAutomationConfig {
  const UiAutomationConfig({
    this.enabled = true,
    this.allowInput = true,
    this.allowRawCoordinates = false,
    this.includeTextFieldValues = false,
    this.limits = const UiAutomationLimits(),
  });

  final bool enabled;
  final bool allowInput;
  final bool allowRawCoordinates;
  final bool includeTextFieldValues;
  final UiAutomationLimits limits;

  bool sameAs(UiAutomationConfig other) =>
      enabled == other.enabled &&
      allowInput == other.allowInput &&
      allowRawCoordinates == other.allowRawCoordinates &&
      includeTextFieldValues == other.includeTextFieldValues &&
      limits.sameAs(other.limits);

  void validate() => limits.validate();
}

enum UiMatchMode {
  exact,
  contains,
  startsWith;

  static UiMatchMode parse(Object? value) => switch (value) {
    null || 'exact' => exact,
    'contains' => contains,
    'starts_with' => startsWith,
    _ => throw UiAutomationError(
      'invalid_selector',
      'match must be exact, contains, or starts_with',
    ),
  };
}

class UiSelector {
  const UiSelector({
    this.id,
    this.identifier,
    this.label,
    this.text,
    this.value,
    this.hint,
    this.tooltip,
    this.action,
    this.viewId,
    this.enabled,
    this.focused,
    this.textField,
    this.nth,
    this.match = UiMatchMode.exact,
    this.caseSensitive = true,
  });

  factory UiSelector.fromJson(Map<String, dynamic> json) {
    const allowed = {
      'id',
      'identifier',
      'label',
      'text',
      'value',
      'hint',
      'tooltip',
      'action',
      'view_id',
      'enabled',
      'focused',
      'text_field',
      'nth',
      'match',
      'case_sensitive',
    };
    final extra = json.keys.where((key) => !allowed.contains(key)).toList();
    if (extra.isNotEmpty) {
      throw UiAutomationError(
        'invalid_selector',
        'unknown selector fields: ${extra.join(', ')}',
      );
    }

    T? read<T>(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! T) {
        throw UiAutomationError('invalid_selector', '$key has the wrong type');
      }
      return value;
    }

    final selector = UiSelector(
      id: read<int>('id'),
      identifier: read<String>('identifier'),
      label: read<String>('label'),
      text: read<String>('text'),
      value: read<String>('value'),
      hint: read<String>('hint'),
      tooltip: read<String>('tooltip'),
      action: read<String>('action'),
      viewId: read<int>('view_id'),
      enabled: read<bool>('enabled'),
      focused: read<bool>('focused'),
      textField: read<bool>('text_field'),
      nth: read<int>('nth'),
      match: UiMatchMode.parse(json['match']),
      caseSensitive: read<bool>('case_sensitive') ?? true,
    );
    if (!selector.hasConstraint) {
      throw UiAutomationError(
        'invalid_selector',
        'selector must contain at least one match field',
      );
    }
    if (selector.id != null && selector.viewId == null) {
      throw const UiAutomationError(
        'invalid_selector',
        'view_id is required with id',
      );
    }
    if ((selector.id != null && selector.id! < 0) ||
        (selector.viewId != null && selector.viewId! < 0)) {
      throw const UiAutomationError(
        'invalid_selector',
        'id and view_id must not be negative',
      );
    }
    if (selector.nth != null && selector.nth! < 0) {
      throw const UiAutomationError(
        'invalid_selector',
        'nth must not be negative',
      );
    }
    for (final value in [
      selector.identifier,
      selector.label,
      selector.text,
      selector.value,
      selector.hint,
      selector.tooltip,
    ]) {
      if (value != null && value.isEmpty) {
        throw const UiAutomationError(
          'invalid_selector',
          'selector strings must not be empty',
        );
      }
    }
    if (selector.action != null &&
        !uiActionNames.containsKey(selector.action)) {
      throw UiAutomationError(
        'invalid_selector',
        'unknown action: ${selector.action}',
      );
    }
    return selector;
  }

  final int? id;
  final String? identifier;
  final String? label;
  final String? text;
  final String? value;
  final String? hint;
  final String? tooltip;
  final String? action;
  final int? viewId;
  final bool? enabled;
  final bool? focused;
  final bool? textField;
  final int? nth;
  final UiMatchMode match;
  final bool caseSensitive;

  bool get hasConstraint =>
      id != null ||
      identifier != null ||
      label != null ||
      text != null ||
      value != null ||
      hint != null ||
      tooltip != null ||
      action != null ||
      viewId != null ||
      enabled != null ||
      focused != null ||
      textField != null;

  bool matches(UiNode node) {
    if (id != null && node.id != id) return false;
    if (viewId != null && node.viewId != viewId) return false;
    if (!node.visible) return false;
    // nodes without an enabled state count as enabled, so enabled=true
    // means "not explicitly disabled" rather than "carries the flag"
    if (enabled != null && (node.enabled ?? true) != enabled) return false;
    if (focused != null && node.focused != focused) return false;
    if (textField != null && node.textField != textField) return false;
    if (action != null && !node.actions.contains(action)) return false;
    if (!_matches(identifier, node.identifier)) return false;
    if (!_matches(label, node.label)) return false;
    if (!_matches(value, node.value)) return false;
    if (!_matches(hint, node.hint)) return false;
    if (!_matches(tooltip, node.tooltip)) return false;
    if (text != null &&
        !_matches(text, node.label) &&
        !_matches(text, node.value) &&
        !_matches(text, node.hint) &&
        !_matches(text, node.tooltip)) {
      return false;
    }
    return true;
  }

  bool _matches(String? wanted, String? actual) {
    if (wanted == null) return true;
    if (actual == null) return false;
    var needle = wanted;
    var candidate = actual;
    if (!caseSensitive) {
      needle = needle.toLowerCase();
      candidate = candidate.toLowerCase();
    }
    return switch (match) {
      UiMatchMode.exact => candidate == needle,
      UiMatchMode.contains => candidate.contains(needle),
      UiMatchMode.startsWith => candidate.startsWith(needle),
    };
  }
}

class UiRect {
  const UiRect(this.left, this.top, this.width, this.height);

  factory UiRect.fromRect(ui.Rect rect) =>
      UiRect(rect.left, rect.top, rect.width, rect.height);

  final double left;
  final double top;
  final double width;
  final double height;

  ui.Offset get center => ui.Offset(left + width / 2, top + height / 2);

  Map<String, Object> toJson() => {
    'x': left,
    'y': top,
    'width': width,
    'height': height,
  };
}

class UiNode {
  const UiNode({
    required this.id,
    required this.viewId,
    required this.parentId,
    required this.identifier,
    required this.label,
    required this.value,
    required this.valueRedacted,
    required this.hint,
    required this.tooltip,
    required this.logicalRect,
    required this.physicalRect,
    required this.visible,
    required this.enabled,
    required this.focused,
    required this.textField,
    required this.readOnly,
    required this.obscured,
    required this.selected,
    required this.checked,
    required this.toggled,
    required this.expanded,
    required this.actions,
    required this.scrollPosition,
    required this.scrollExtentMin,
    required this.scrollExtentMax,
  });

  final int id;
  final int viewId;
  final int? parentId;
  final String? identifier;
  final String? label;
  final String? value;
  final bool valueRedacted;
  final String? hint;
  final String? tooltip;
  final UiRect logicalRect;
  final UiRect physicalRect;
  final bool visible;
  final bool? enabled;
  final bool focused;
  final bool textField;
  final bool readOnly;
  final bool obscured;
  final bool? selected;
  final Object? checked;
  final bool? toggled;
  final bool? expanded;
  final Set<String> actions;
  final double? scrollPosition;
  final double? scrollExtentMin;
  final double? scrollExtentMax;

  Map<String, Object?> toJson() => {
    'id': id,
    'view_id': viewId,
    if (parentId != null) 'parent_id': parentId,
    if (identifier != null) 'identifier': identifier,
    if (label != null) 'label': label,
    if (value != null) 'value': value,
    if (valueRedacted) 'value_redacted': true,
    if (hint != null) 'hint': hint,
    if (tooltip != null) 'tooltip': tooltip,
    'rect': logicalRect.toJson(),
    'physical_rect': physicalRect.toJson(),
    'visible': visible,
    if (enabled != null) 'enabled': enabled,
    'focused': focused,
    'text_field': textField,
    if (readOnly) 'read_only': true,
    if (obscured) 'obscured': true,
    if (selected != null) 'selected': selected,
    if (checked != null) 'checked': checked,
    if (toggled != null) 'toggled': toggled,
    if (expanded != null) 'expanded': expanded,
    'actions': actions.toList()..sort(),
    if (scrollPosition != null) 'scroll_position': scrollPosition,
    if (scrollExtentMin != null) 'scroll_extent_min': scrollExtentMin,
    if (scrollExtentMax != null) 'scroll_extent_max': scrollExtentMax,
  };
}

class UiViewSnapshot {
  const UiViewSnapshot({
    required this.viewId,
    required this.devicePixelRatio,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.physicalWidth,
    required this.physicalHeight,
  });

  final int viewId;
  final double devicePixelRatio;
  final double logicalWidth;
  final double logicalHeight;
  final double physicalWidth;
  final double physicalHeight;

  Map<String, Object> toJson() => {
    'view_id': viewId,
    'device_pixel_ratio': devicePixelRatio,
    'logical_width': logicalWidth,
    'logical_height': logicalHeight,
    'physical_width': physicalWidth,
    'physical_height': physicalHeight,
  };
}

class UiSnapshot {
  const UiSnapshot({
    required this.id,
    required this.createdAt,
    required this.views,
    required this.nodes,
    required this.truncated,
  });

  final int id;
  final DateTime createdAt;
  final List<UiViewSnapshot> views;
  final List<UiNode> nodes;
  final bool truncated;

  List<UiNode> find(UiSelector selector) =>
      nodes.where(selector.matches).toList(growable: false);

  Map<String, Object?> toJson() => {
    'ok': true,
    'snapshot_id': id,
    'created_at': createdAt.toUtc().toIso8601String(),
    'views': views.map((view) => view.toJson()).toList(),
    'count': nodes.length,
    'truncated': truncated,
    'nodes': nodes.map((node) => node.toJson()).toList(),
  };
}

class UiAutomationError implements Exception {
  const UiAutomationError(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  Map<String, Object?> toJson() => {
    'ok': false,
    'error': {
      'code': code,
      'message': message,
      if (details != null) 'details': details,
    },
  };

  @override
  String toString() => 'UiAutomationError($code, $message)';
}

class UiNodeHandle {
  const UiNodeHandle({
    required this.node,
    required this.semanticsNode,
    required this.owner,
  });

  final UiNode node;
  final SemanticsNode semanticsNode;
  final SemanticsOwner owner;
}

class UiInspection {
  const UiInspection(this.snapshot, this.handles);

  final UiSnapshot snapshot;
  final Map<String, UiNodeHandle> handles;

  UiNodeHandle handleFor(UiNode node) => handles['${node.viewId}:${node.id}']!;
}
