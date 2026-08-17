import 'package:ai_debug/src/builtins/legacy_io_tools.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  String? clipboard;

  setUp(() {
    calls.clear();
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return switch (call.method) {
            'Clipboard.getData' =>
              clipboard == null ? null : <String, Object?>{'text': clipboard},
            'Clipboard.setData' => null,
            'HapticFeedback.vibrate' => null,
            'SystemSound.play' => null,
            _ => throw MissingPluginException(call.method),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('registers bounded and annotated runtime controls', () {
    final registry = CommandRegistry();
    registerLegacyIoTools(registry);

    expect(registry.all.map((tool) => tool.name), [
      'runtime.clipboard_get',
      'runtime.clipboard_set',
      'runtime.haptic',
      'runtime.system_sound',
    ]);
    expect(registry.get('runtime.clipboard_get')!.annotations, {
      'readOnlyHint': true,
      'openWorldHint': true,
    });
    expect(registry.get('runtime.clipboard_set')!.annotations, {
      'readOnlyHint': false,
      'destructiveHint': true,
      'openWorldHint': true,
    });
    expect(
      registry.get('runtime.clipboard_get')!.inputSchema.asJson['properties'],
      contains('maxChars'),
    );
  });

  test(
    'clipboard read is bounded without splitting a surrogate pair',
    () async {
      clipboard = 'ab😀c';
      final registry = CommandRegistry();
      registerLegacyIoTools(registry);

      final result = await registry.dispatch('runtime.clipboard_get', {
        'maxChars': 3,
      });

      expect(result.json, {
        'text': 'ab',
        'length': 5,
        'returnedChars': 2,
        'truncated': true,
      });
      expect(calls.single, isA<MethodCall>());
      expect(calls.single.method, 'Clipboard.getData');
    },
  );

  test(
    'clipboard write calls Flutter service and rejects oversized text',
    () async {
      final registry = CommandRegistry();
      registerLegacyIoTools(registry);

      expect(
        (await registry.dispatch('runtime.clipboard_set', {
          'text': 'hello',
        })).json,
        {'ok': true, 'length': 5},
      );
      expect(calls.single.method, 'Clipboard.setData');
      expect(calls.single.arguments, {'text': 'hello'});
      await expectLater(
        registry.dispatch('runtime.clipboard_set', {
          'text': 'x' * (legacyIoMaxClipboardChars + 1),
        }),
        throwsA(isA<AiDebugSchemaError>()),
      );
      expect(calls, hasLength(1));
    },
  );

  test('haptic kinds map to one bounded platform call', () async {
    final registry = CommandRegistry();
    registerLegacyIoTools(registry);
    const args = {
      'vibrate': null,
      'light': 'HapticFeedbackType.lightImpact',
      'medium': 'HapticFeedbackType.mediumImpact',
      'heavy': 'HapticFeedbackType.heavyImpact',
      'selection': 'HapticFeedbackType.selectionClick',
    };

    for (final entry in args.entries) {
      calls.clear();
      expect(
        (await registry.dispatch('runtime.haptic', {'kind': entry.key})).json,
        {'ok': true, 'kind': entry.key},
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'HapticFeedback.vibrate');
      expect(calls.single.arguments, entry.value);
    }
  });

  test('system sounds map to one bounded platform call', () async {
    final registry = CommandRegistry();
    registerLegacyIoTools(registry);

    for (final kind in ['click', 'alert']) {
      calls.clear();
      expect(
        (await registry.dispatch('runtime.system_sound', {'kind': kind})).json,
        {'ok': true, 'kind': kind},
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'SystemSound.play');
      expect(calls.single.arguments.toString(), 'SystemSoundType.$kind');
    }
  });
}
