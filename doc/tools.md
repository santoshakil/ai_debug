# Tools

Tool definitions, schemas, annotations, and limits are returned by
`GET /api/tools` and MCP `tools/list`. Lists are paged when needed.

The package has 102 gated tools. The server adds `list_apps` for every config
and `tail_logs` when logs are enabled. This gives 31 tools with default features
and 104 with `AiDebugFeatures.all()`.

## Transport tools

| Tool | Gate | Purpose |
| --- | --- | --- |
| `list_apps` | always | current app endpoint and identity |
| `tail_logs` | `logs` | bounded filtered Dart log history |

## Feature gates

| Gate | Tools |
| --- | --- |
| `diagnostics` | `devtools.focus`, `errors.history`, `errors.status` |
| `logs` | `logs.status` |
| `state` | `state.history`, `state.snapshot`, `state.sources` |
| `isolates` | `isolates.events`, `isolates.status` |
| `screenshots` | `screenshot` |
| `automation` | `ui.activate`, `ui.capabilities`, `ui.double_tap`, `ui.drag`, `ui.find`, `ui.long_press`, `ui.pinch`, `ui.run`, `ui.scroll`, `ui.scroll_until`, `ui.snapshot`, `ui.tap`, `ui.wait` |
| `navigation` | `app.back`, `app.navigate`, `app.pop_until`, `app.replace`, `app.routes` |
| `network` | `network.connect`, `network.history`, `network.http_probe`, `network.interfaces`, `network.resolve`, `network.status` |
| `files` | `files.directory_size`, `files.list`, `files.read_bytes`, `files.read_text`, `files.roots`, `files.stat`, `files.walk` |
| `telemetry` | `telemetry.emit`, `telemetry.flush`, `telemetry.start`, `telemetry.status`, `telemetry.stop` |
| `vmService` | `vm.allocations`, `vm.cpu`, `vm.isolates`, `vm.memory`, `vm.stack`, `vm.status`, `vm.timeline` |

The `resources` gate contains the in-process DevTools views:

- `app.lifecycle`, `app.lifecycle_history`
- `dart_version`, `device_info`, `displays`, `memory`, `runtime.clock`
- `devtools.capabilities`
- `devtools.resources.history`, `devtools.resources.sample`,
  `devtools.resources.status`
- `devtools.frames.history`, `devtools.frames.summary`
- `devtools.trace.events`, `devtools.trace.export_chrome`,
  `devtools.trace.status`
- `devtools.ui.layers`, `devtools.ui.render`, `devtools.ui.semantics`,
  `devtools.ui.widgets`

## Runtime controls

`runtimeControls` alone adds:

- `runtime.clock`, `runtime.time_dilation`
- `runtime.performance_overlay`, `runtime.reassemble`,
  `runtime.schedule_frame`
- `runtime.clipboard_get`, `runtime.clipboard_set`, `runtime.haptic`,
  `runtime.system_sound`

It also adds controls to each enabled read gate:

| Read gate | Added controls |
| --- | --- |
| `diagnostics` | `devtools.debug_flags`, `errors.clear` |
| `logs` | `logs.clear`, `logs.emit`, `logs.level` |
| `state` | `state.clear` |
| `isolates` | `isolates.clear` |
| `network` | `network.clear` |
| `resources` | `app.lifecycle_clear`, `devtools.frames.clear`, `devtools.frames.start`, `devtools.frames.stop`, `devtools.resources.clear`, `devtools.resources.start`, `devtools.resources.stop`, `devtools.trace.clear`, `devtools.trace.instant`, `devtools.trace.span_finish`, `devtools.trace.span_start`, `devtools.trace.start`, `devtools.trace.stop` |
| `vmService` | enables the `gc` and `reset` arguments on `vm.allocations` |

`discovery` adds no tool. It advertises an enabled non-loopback server through
mDNS and requires `unsafeLan: true` plus a strong token.

## Scope and limits

- Widget, render, layer, semantics, focus, automation, history, and trace
  results are bounded. A tree can report truncation when its node or depth cap
  is reached.
- Automation selectors require semantics data. Input is serialized and disabled
  when `UiAutomationConfig.allowInput` is false.
- Prefer semantic identifiers. For unlabeled controls, selectors accept the
  `id` and `view_id` pair returned by a snapshot while that node stays attached.
- `network.resolve`, `network.connect`, and `network.http_probe` make outbound
  requests. Network history includes only explicitly tracked app requests.
- File tools require absolute configured roots. Reads, walks, response sizes,
  and concurrent streams are bounded.
- Telemetry sends only explicitly queued bounded events. It accepts HTTPS and
  loopback HTTP collectors.
- VM tools need a reachable VM service. CPU samples also need the VM sampling
  profiler to be enabled by the runtime or host tooling.
- A timed-out tool returns an error to the caller but keeps the serial slot until
  its Dart future settles.

## Deliberately absent

The package does not expose arbitrary platform-channel invocation, environment
variables, subprocess disk probes, raw HTTP POST, forced app errors, long sleep
tools, fake GC, SystemChrome mutation, or orientation mutation. GPU, thermal,
battery, native heap, and host-wide traffic require native or host tooling.
