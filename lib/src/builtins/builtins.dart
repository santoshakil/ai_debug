import '../config.dart';
import '../registry.dart';
import 'automation_tools.dart';
import 'devtools_tools.dart';
import 'diagnostics_tools.dart';
import 'error_monitor_tools.dart';
import 'filesystem_tools.dart';
import 'isolate_tools.dart';
import 'legacy_io_tools.dart';
import 'log_tools.dart';
import 'navigation_tools.dart';
import 'network_tools.dart';
import 'network_monitor_tools.dart';
import 'observer_tools.dart';
import 'runtime_tools.dart';
import 'screenshot_tool.dart';
import 'state_inspector_tools.dart';
import 'system_tools.dart';
import 'telemetry_tools.dart';
import 'time_tools.dart';
import 'vm_service_tools.dart';

void registerAllBuiltinTools(CommandRegistry registry, AiDebugConfig config) {
  final features = config.features;
  if (features.resources) {
    registerDevToolsTools(
      registry,
      controls: features.runtimeControls,
      vmServiceEnabled: features.vmService,
    );
    registerSystemTools(registry);
    registerObserverTools(registry, controls: features.runtimeControls);
  }
  if (features.diagnostics) {
    registerDiagnosticsTools(registry, controls: features.runtimeControls);
    registerErrorMonitorTools(registry, controls: features.runtimeControls);
  }
  if (features.logs) {
    registerLogTools(registry, controls: features.runtimeControls);
  }
  if (features.state) {
    registerStateInspectorTools(registry, controls: features.runtimeControls);
  }
  if (features.isolates) {
    registerIsolateTools(registry, controls: features.runtimeControls);
  }
  if (features.screenshots) registerScreenshotTool(registry);
  if (features.automation) {
    registerAutomationTools(registry, config: config.automation);
  }
  if (features.navigation) registerNavigationTools(registry);
  if (features.network) {
    registerNetworkMonitorTools(registry, controls: features.runtimeControls);
    registerNetworkTools(registry);
  }
  if (features.files) {
    registerFilesystemTools(registry, allowedRoots: config.allowedFileRoots);
  }
  if (features.resources || features.runtimeControls) {
    registerTimeTools(registry, controls: features.runtimeControls);
  }
  if (features.runtimeControls) {
    registerRuntimeTools(registry);
    registerLegacyIoTools(registry);
  }
  if (features.telemetry) registerTelemetryTools(registry);
  if (features.vmService) {
    registerVmServiceTools(registry, controls: features.runtimeControls);
  }
}
