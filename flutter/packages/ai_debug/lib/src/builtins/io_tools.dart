import 'package:flutter/services.dart';

import '../registry.dart';

/// Register I/O tools: clipboard read/write, haptic feedback, device vibration.
void registerIOTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'clipboard_get',
    description: 'Read current clipboard text contents.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return {'text': data?.text};
    },
  ));

  registry.add(ToolEntry(
    name: 'clipboard_set',
    description: 'Write text to the clipboard.',
    inputSchema: AiDebugSchema.object(
      {'text': AiDebugSchema.string()},
      required: ['text'],
    ),
    handler: (args) async {
      await Clipboard.setData(ClipboardData(text: args['text'] as String));
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'haptic_feedback',
    description: 'Trigger haptic feedback on the device.',
    inputSchema: AiDebugSchema.object({
      'kind': AiDebugSchema.string(
        default_: 'light',
        enum_: ['light', 'medium', 'heavy', 'selection', 'vibrate'],
      ),
    }),
    handler: (args) async {
      final kind = (args['kind'] as String?) ?? 'light';
      switch (kind) {
        case 'medium':
          await HapticFeedback.mediumImpact();
          break;
        case 'heavy':
          await HapticFeedback.heavyImpact();
          break;
        case 'selection':
          await HapticFeedback.selectionClick();
          break;
        case 'vibrate':
          await HapticFeedback.vibrate();
          break;
        case 'light':
        default:
          await HapticFeedback.lightImpact();
      }
      return {'ok': true};
    },
  ));

  registry.add(ToolEntry(
    name: 'system_sound',
    description: 'Play a system UI sound.',
    inputSchema: AiDebugSchema.object({
      'kind': AiDebugSchema.string(
        default_: 'click',
        enum_: ['click', 'alert'],
      ),
    }),
    handler: (args) async {
      final kind = (args['kind'] as String?) ?? 'click';
      await SystemSound.play(kind == 'alert' ? SystemSoundType.alert : SystemSoundType.click);
      return {'ok': true};
    },
  ));
}
