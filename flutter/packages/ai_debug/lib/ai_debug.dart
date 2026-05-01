/// Embedded MCP debug bridge for Flutter apps.
///
/// Plug-and-play: `AiDebug.start(appId: 'my_app')` + `AiDebug.register(...)`.
library;

export 'src/ai_debug.dart';
export 'src/registry.dart' show AiDebugHandler, AiDebugSchema, AiDebugResult;
