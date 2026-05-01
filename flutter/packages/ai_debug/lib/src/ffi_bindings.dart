/// FFI bindings entry point.
///
/// All FFI function declarations and the `ByteBuffer` struct are produced by
/// `ffigen` from the cbindgen-generated header at
/// `rust/generated/ai_debug.h`. Re-run with `dart run ffigen` from this
/// package's directory after changing the Rust FFI surface.
///
/// The generated file uses `@ffi.DefaultAsset('package:ai_debug/src/ai_debug.dart')`,
/// so Flutter resolves the native symbols via the `hooks` + `native_toolchain_rust`
/// asset produced by `hook/build.dart`. No runtime `DynamicLibrary.open` needed
/// on supported platforms.
library;

export 'generated/bindings.dart';
