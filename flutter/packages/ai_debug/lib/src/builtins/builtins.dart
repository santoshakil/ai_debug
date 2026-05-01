import '../registry.dart';
import 'diagnostics_tools.dart';
import 'error_tools.dart';
import 'filesystem_tools.dart';
import 'io_tools.dart';
import 'log_tools.dart';
import 'navigation_tools.dart';
import 'network_tools.dart';
import 'observer_tools.dart';
import 'platform_channel_tools.dart';
import 'runtime_tools.dart';
import 'screenshot_tool.dart';
import 'state_inspector_tools.dart';
import 'system_tools.dart';
import 'telemetry_tools.dart';
import 'time_tools.dart';
import 'vm_tools.dart';
import 'wait_tools.dart';

/// Register every built-in tool into the given [CommandRegistry].
///
/// Called by `Bridge.start` after the native server is up so the tools
/// announce themselves via the RegisterTool envelopes.
void registerAllBuiltinTools(CommandRegistry registry) {
  registerSystemTools(registry);
  registerDiagnosticsTools(registry);
  registerIOTools(registry);
  registerRuntimeTools(registry);
  registerNavigationTools(registry);
  registerStateInspectorTools(registry);
  registerScreenshotTool(registry);
  registerNetworkTools(registry);
  registerFilesystemTools(registry);
  registerErrorTools(registry);
  registerTimeTools(registry);
  registerVmTools(registry);
  registerWaitTools(registry);
  registerPlatformChannelTools(registry);
  registerObserverTools(registry);
  registerLogTools(registry);
  registerTelemetryTools(registry);
}
