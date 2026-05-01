//! Global state: tokio runtime, oneshot registry for pending tool calls,
//! broadcast channels for streams, and the single event port to Dart.

use crate::events::NativeEventPort;
use crate::registry::ToolRegistry;
use crate::logs::LogBuffer;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use tokio::runtime::Runtime;
use tokio::sync::oneshot;

/// Static tokio runtime. Per Pattern H: FFI + long-running → static runtime.
pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .thread_name("ai_debug")
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("failed to build tokio runtime")
});

/// Single event port for Rust → Dart messages.
pub static EVENTS: NativeEventPort = NativeEventPort::new();

/// In-memory log ring buffer (Rust tracing + merged Dart snapshots).
pub static LOGS: Lazy<LogBuffer> = Lazy::new(LogBuffer::new);

/// Tool registry: name → metadata + handler_id. Mirrored from Dart registrations.
pub static TOOLS: Lazy<ToolRegistry> = Lazy::new(ToolRegistry::new);

/// Pending tool invocations: request_id → oneshot sender.
pub static PENDING: Lazy<Mutex<HashMap<i64, oneshot::Sender<PendingResult>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

static NEXT_ID: AtomicI64 = AtomicI64::new(1);
pub fn next_request_id() -> i64 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

#[derive(Debug)]
pub struct PendingResult {
    pub success: bool,
    pub error: Option<String>,
    pub result_json: Option<String>,
    pub binary: Option<Vec<u8>>,
    pub binary_mime: Option<String>,
}
