# Contributing to ai_debug

Thanks for helping. This is a small library; contributions of any size are welcome.

## Repo layout

```
.
├── rust/crates/ai_debug   — Rust cdylib (MCP server, FFI, tracing, mDNS)
├── flutter/packages/ai_debug  — Flutter package (Dart side)
├── protos/                — protobuf schemas (cross-lang FFI types)
├── examples/minimal_app   — Flutter example wiring
├── tools/                 — telemetry collector + watcher + analyzer
├── scripts/               — setup + codegen helpers
└── docs/                  — integration guide
```

## Local setup

1. Install Rust (1.78+), Flutter (3.22+), `protoc` (3.20+).
2. `./scripts/setup.sh` — installs `protoc_plugin`, ffigen, dart deps.
3. `cargo check -p ai_debug` — verify Rust compiles.
4. `cd flutter/packages/ai_debug && flutter pub get && flutter analyze`
5. `cd examples/minimal_app && flutter run`

## Codegen

After editing `protos/ai_debug.proto`:
```bash
./scripts/generate_proto.sh
```
This regenerates both Rust (`prost-build` via `build.rs`) and Dart (`protoc_plugin`) sources.

After changing the FFI surface (`rust/crates/ai_debug/src/ffi.rs`):
```bash
cargo build -p ai_debug   # regenerates rust/generated/ai_debug.h via cbindgen
cd flutter/packages/ai_debug && dart run ffigen
```

## Coding conventions

- **Rust**: zero `unwrap`/`expect` on FFI boundary. Use `tracing` (no `println!` in production code). `#[tracing::instrument]` async functions when useful.
- **Dart**: use `package:logging` `Logger` — never `print` (the package collects `Logger.root` records). `dPrint(() => "...")` style if you need debug-only logs.
- **Errors over the wire**: every FFI boundary returns a typed protobuf result; never panic across the boundary.
- **No PII in logs**: assume an ai_debug-instrumented app might be tailed by an external agent. The library defaults to debug-mode-only when integrated correctly.

## Testing

- Rust: `cargo test -p ai_debug` (unit only — integration covered by example app).
- Flutter: `cd flutter/packages/ai_debug && flutter test`.
- Manual end-to-end: run `examples/minimal_app`, `curl http://localhost:9999/healthz`, then `curl http://localhost:9999/api/tools`.

## Filing issues

- Describe the platform (host OS, Flutter version, target device).
- Attach the relevant `tools/collector.py` JSONL slice if reproducible via telemetry.
- For FFI / build issues, paste the full `cargo build -p ai_debug` output.

## PRs

- Keep changes focused. Add a one-line CHANGELOG entry under `## [Unreleased]`.
- Run `cargo clippy -p ai_debug -- -D warnings` and `flutter analyze` before pushing.
