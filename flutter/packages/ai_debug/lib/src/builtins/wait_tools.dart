import 'dart:async';

import '../registry.dart';

/// Wait/sleep helpers for autonomous test scripting.
void registerWaitTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'sleep',
    description:
        'Sleep for ms. Used to add a deterministic gap inside a test sequence — '
        'note: this blocks the calling tool, not the rest of the app (Flutter UI keeps running).',
    inputSchema: AiDebugSchema.object(
      {'ms': AiDebugSchema.integer(min: 0, max: 600000)},
      required: ['ms'],
    ),
    handler: (args) async {
      final ms = (args['ms'] as num).toInt();
      final sw = Stopwatch()..start();
      await Future<void>.delayed(Duration(milliseconds: ms));
      sw.stop();
      return {'ok': true, 'requestedMs': ms, 'actualMs': sw.elapsedMilliseconds};
    },
  ));

  registry.add(ToolEntry(
    name: 'sleep_until',
    description:
        'Sleep until a wall clock millisecond timestamp. Useful for syncing autonomous test '
        'segments. Returns immediately if target is in the past.',
    inputSchema: AiDebugSchema.object(
      {'targetWallMs': AiDebugSchema.integer(min: 0)},
      required: ['targetWallMs'],
    ),
    handler: (args) async {
      final target = (args['targetWallMs'] as num).toInt();
      final now = DateTime.now().millisecondsSinceEpoch;
      final delta = target - now;
      if (delta <= 0) return {'ok': true, 'note': 'target in past', 'deltaMs': delta};
      await Future<void>.delayed(Duration(milliseconds: delta));
      return {'ok': true, 'sleptMs': delta};
    },
  ));
}
