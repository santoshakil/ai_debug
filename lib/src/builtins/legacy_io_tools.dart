import 'package:flutter/services.dart';

import '../registry.dart';

const legacyIoMaxClipboardChars = 65536;

void registerLegacyIoTools(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'runtime.clipboard_get',
      title: 'Read device clipboard',
      description:
          'Read bounded plain text from the device clipboard. Requires runtimeControls.',
      inputSchema: AiDebugSchema.object({
        'maxChars': AiDebugSchema.integer(
          min: 1,
          max: legacyIoMaxClipboardChars,
          default_: legacyIoMaxClipboardChars,
        ),
      }),
      annotations: _clipboardRead,
      handler: (args) async {
        final maxChars = args['maxChars'] as int? ?? legacyIoMaxClipboardChars;
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (text == null) {
          return {
            'text': null,
            'length': 0,
            'returnedChars': 0,
            'truncated': false,
          };
        }
        final value = _prefix(text, maxChars);
        return {
          'text': value,
          'length': text.length,
          'returnedChars': value.length,
          'truncated': value.length < text.length,
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'runtime.clipboard_set',
      title: 'Write device clipboard',
      description:
          'Replace device clipboard text with at most 65536 characters. Requires runtimeControls.',
      inputSchema: AiDebugSchema.object(
        {'text': AiDebugSchema.string(maxLength: legacyIoMaxClipboardChars)},
        required: ['text'],
      ),
      annotations: _clipboardWrite,
      handler: (args) async {
        final text = args['text'] as String;
        if (text.length > legacyIoMaxClipboardChars) {
          throw RangeError.range(
            text.length,
            0,
            legacyIoMaxClipboardChars,
            'text.length',
          );
        }
        await Clipboard.setData(ClipboardData(text: text));
        return {'ok': true, 'length': text.length};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'runtime.haptic',
      title: 'Trigger device haptic feedback',
      description:
          'Trigger one supported Flutter haptic feedback event. Requires runtimeControls.',
      inputSchema: AiDebugSchema.object({
        'kind': AiDebugSchema.string(
          enum_: const ['vibrate', 'light', 'medium', 'heavy', 'selection'],
          default_: 'light',
        ),
      }),
      annotations: _deviceControl,
      handler: (args) async {
        final kind = args['kind'] as String? ?? 'light';
        await switch (kind) {
          'vibrate' => HapticFeedback.vibrate(),
          'light' => HapticFeedback.lightImpact(),
          'medium' => HapticFeedback.mediumImpact(),
          'heavy' => HapticFeedback.heavyImpact(),
          'selection' => HapticFeedback.selectionClick(),
          _ => throw ArgumentError.value(kind, 'kind'),
        };
        return {'ok': true, 'kind': kind};
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'runtime.system_sound',
      title: 'Play a system sound',
      description:
          'Play one supported Flutter system sound. Requires runtimeControls.',
      inputSchema: AiDebugSchema.object({
        'kind': AiDebugSchema.string(
          enum_: const ['click', 'alert'],
          default_: 'click',
        ),
      }),
      annotations: _deviceControl,
      handler: (args) async {
        final kind = args['kind'] as String? ?? 'click';
        await SystemSound.play(
          kind == 'alert' ? SystemSoundType.alert : SystemSoundType.click,
        );
        return {'ok': true, 'kind': kind};
      },
    ),
  );
}

String _prefix(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  var end = maxChars;
  if (_isHighSurrogate(value.codeUnitAt(end - 1))) end--;
  return value.substring(0, end);
}

bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;

const _clipboardRead = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': true,
};

const _clipboardWrite = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': true,
};

const _deviceControl = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': false,
};
