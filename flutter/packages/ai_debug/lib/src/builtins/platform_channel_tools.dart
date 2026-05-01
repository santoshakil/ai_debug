import 'package:flutter/services.dart';

import '../registry.dart';

/// Direct platform-channel invocations. Lets a test driver call any method on
/// any registered Flutter MethodChannel without writing a tool wrapper.
void registerPlatformChannelTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'platform_invoke',
    description:
        'Invoke a method on a Flutter MethodChannel by name. Returns the channel\'s '
        'response (auto-converted to JSON). Throws if the channel is missing or method errors. '
        'Useful when the app exposes platform APIs that have no ai_debug wrapper yet.',
    inputSchema: AiDebugSchema.object(
      {
        'channel': AiDebugSchema.string(description: 'e.g. plugins.flutter.io/path_provider'),
        'method': AiDebugSchema.string(),
        'args': AiDebugSchema.object({}),
      },
      required: ['channel', 'method'],
    ),
    handler: (args) async {
      final ch = args['channel'] as String;
      final m = args['method'] as String;
      final params = args['args'];
      try {
        final result = await MethodChannel(ch).invokeMethod<Object?>(m, params);
        return {'ok': true, 'result': _normalize(result)};
      } on MissingPluginException catch (e) {
        return {'ok': false, 'error': 'missing-plugin', 'detail': e.message, 'channel': ch};
      } on PlatformException catch (e) {
        return {
          'ok': false,
          'error': 'platform',
          'code': e.code,
          'message': e.message,
          'detail': e.details?.toString(),
          'stack': e.stacktrace,
        };
      } catch (e) {
        return {'ok': false, 'error': e.toString()};
      }
    },
  ));
}

Object? _normalize(Object? v) {
  if (v == null || v is bool || v is num || v is String) return v;
  if (v is List) return v.map(_normalize).toList();
  if (v is Map) {
    return v.map((k, val) => MapEntry(k.toString(), _normalize(val)));
  }
  return v.toString();
}
