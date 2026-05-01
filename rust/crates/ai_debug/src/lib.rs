//! ai_debug — embedded MCP debug bridge for Flutter apps.
//!
//! Exposes a tiny FFI surface (`ai_debug_init`, `ai_debug_send`) consumed by the
//! Dart `ai_debug` package. Starts an axum HTTP server on a dynamic port that
//! serves the MCP protocol to remote AI agents. Dispatches tool invocations
//! to Dart via an `irondash` NativeEventPort.

#![allow(clippy::missing_safety_doc)]

pub mod client;
pub mod events;
pub mod ffi;
pub mod files;
pub mod logs;
pub mod mcp;
pub mod mdns;
pub mod registry;
pub mod server;
pub mod state;

// Generated proto types live at src/pb/ai_debug.rs (gitignored).
#[allow(clippy::all, clippy::pedantic)]
#[path = "pb/ai_debug.rs"]
pub mod pb;

pub use pb::*;

/// Re-exported so cbindgen finds it in the root for header generation.
pub use ffi::{ai_debug_init, ai_debug_send, ai_debug_shutdown, ByteBuffer, free_buffer};
