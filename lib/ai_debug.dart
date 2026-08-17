library;

export 'src/ai_debug.dart';
export 'src/config.dart' show AiDebugConfig, AiDebugFeatures;
export 'src/automation/target.dart' show AiDebugTarget;
export 'src/automation/models.dart' show UiAutomationConfig, UiAutomationLimits;
export 'src/devtools/trace_recorder.dart' show TraceSpan;
export 'src/isolates/isolate_hub.dart' show AiDebugIsolateClient;
export 'src/log_buffer.dart' show AiDebugLogRecord;
export 'src/observability/network_monitor.dart' show NetworkRequest;
export 'src/navigation/navigation_adapter.dart'
    show
        NavigationAdapter,
        RouteBack,
        RouteNavigate,
        RoutePopUntil,
        RouteReplace,
        RouteSnapshot;
export 'src/registry.dart' show AiDebugHandler, AiDebugSchema, AiDebugResult;
export 'src/state/state_registry.dart'
    show StateChanges, StateRead, StateRedactor, StateSnapshot, StateSource;
