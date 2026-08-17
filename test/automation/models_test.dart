import 'package:ai_debug/src/automation/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UiSelector', () {
    test('requires a match field', () {
      expect(
        () => UiSelector.fromJson(const {}),
        throwsA(isA<UiAutomationError>()),
      );
    });

    test('rejects unknown fields and actions', () {
      expect(
        () => UiSelector.fromJson(const {'unknown': true}),
        throwsA(isA<UiAutomationError>()),
      );
      expect(
        () => UiSelector.fromJson(const {'action': 'launchMissiles'}),
        throwsA(isA<UiAutomationError>()),
      );
      expect(
        () => UiSelector.fromJson(const {'id': 4}),
        throwsA(isA<UiAutomationError>()),
      );
      for (final key in [
        'identifier',
        'label',
        'text',
        'value',
        'hint',
        'tooltip',
      ]) {
        expect(
          () => UiSelector.fromJson({key: ''}),
          throwsA(isA<UiAutomationError>()),
        );
      }
    });

    test('matches a semantics id within its view', () {
      final selector = UiSelector.fromJson(const {'id': 1, 'view_id': 0});

      expect(selector.matches(_node()), isTrue);
      expect(selector.matches(_node(id: 2)), isFalse);
    });

    test('matches exact text and state by default', () {
      final selector = UiSelector.fromJson(const {
        'identifier': 'save',
        'enabled': true,
      });
      expect(
        selector.matches(_node(identifier: 'save', enabled: true)),
        isTrue,
      );
      expect(
        selector.matches(_node(identifier: 'Save', enabled: true)),
        isFalse,
      );
      expect(
        selector.matches(_node(identifier: 'save', enabled: false)),
        isFalse,
      );
    });

    test('supports bounded case-insensitive contains matching', () {
      final selector = UiSelector.fromJson(const {
        'text': 'BACKUP',
        'match': 'contains',
        'case_sensitive': false,
      });
      expect(selector.matches(_node(label: 'Start backup now')), isTrue);
      expect(selector.matches(_node(hint: 'backup later')), isTrue);
      expect(selector.matches(_node(label: 'Upload')), isFalse);
    });

    test('hidden nodes do not match', () {
      final hidden = _node(identifier: 'hidden', visible: false);
      expect(
        UiSelector.fromJson(const {'identifier': 'hidden'}).matches(hidden),
        isFalse,
      );
      expect(
        () => UiSelector.fromJson(const {
          'identifier': 'hidden',
          'visible': false,
        }),
        throwsA(isA<UiAutomationError>()),
      );
    });

    test('nodes without an enabled state count as enabled', () {
      final selector = UiSelector.fromJson(const {'enabled': true});
      expect(selector.matches(_node(identifier: 'save')), isTrue);
      expect(selector.matches(_node(enabled: false)), isFalse);
      expect(
        UiSelector.fromJson(const {'enabled': false}).matches(_node()),
        isFalse,
      );
    });

    test('nth parses and rejects negatives', () {
      expect(UiSelector.fromJson(const {'label': 'x', 'nth': 1}).nth, 1);
      expect(
        () => UiSelector.fromJson(const {'label': 'x', 'nth': -1}),
        throwsA(isA<UiAutomationError>()),
      );
    });
  });
}

UiNode _node({
  int id = 1,
  String? identifier,
  String? label,
  String? hint,
  bool visible = true,
  bool? enabled,
}) => UiNode(
  id: id,
  viewId: 0,
  parentId: null,
  identifier: identifier,
  label: label,
  value: null,
  valueRedacted: false,
  hint: hint,
  tooltip: null,
  logicalRect: const UiRect(0, 0, 10, 10),
  physicalRect: const UiRect(0, 0, 10, 10),
  visible: visible,
  enabled: enabled,
  focused: false,
  textField: false,
  readOnly: false,
  obscured: false,
  selected: null,
  checked: null,
  toggled: null,
  expanded: null,
  actions: const {'tap'},
  scrollPosition: null,
  scrollExtentMin: null,
  scrollExtentMax: null,
);
