//! FFI surface consumed by the Dart `ai_debug` package.
//!
//! Design: two entry points + one event port.
//!
//! * `ai_debug_init(port, config_ptr, config_len) -> ByteBuffer` —
//!   Dart calls this once at startup. `port` is the Dart `SendPort.nativePort`
//!   obtained from `ReceivePort.sendPort.nativePort`. Returns a protobuf
//!   `InitResult` with the bound socket addr + mDNS info.
//! * `ai_debug_send(ptr, len) -> ByteBuffer` — Dart pushes a `ToRust` envelope.
//!   Returns a `ToRust` ack envelope (for synchronous operations like register).
//! * `ai_debug_shutdown()` — flushes everything, disconnects the event port.

use crate::events::init_dart_api;
use crate::pb::{to_rust, RegisterTool, ToRust, ToolResult, UnregisterTool};
use crate::registry::ToolSpec;
use crate::state::{EVENTS, LOGS, PENDING, RUNTIME, TOOLS};
use prost::Message;
use std::sync::Once;

#[repr(C)]
pub struct ByteBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

impl ByteBuffer {
    pub fn from_vec(mut v: Vec<u8>) -> Self {
        let ptr = v.as_mut_ptr();
        let len = v.len();
        let cap = v.capacity();
        std::mem::forget(v);
        Self { ptr, len, cap }
    }

    pub const fn empty() -> Self {
        Self { ptr: std::ptr::null_mut(), len: 0, cap: 0 }
    }
}

/// Free a `ByteBuffer` returned from Rust. Dart MUST call this in a `finally`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn free_buffer(buf: ByteBuffer) {
    if !buf.ptr.is_null() && buf.cap > 0 {
        drop(Vec::from_raw_parts(buf.ptr, buf.len, buf.cap));
    }
}

static TRACING_INIT: Once = Once::new();

/// Initialise the bridge. Call exactly once.
///
/// # Safety
/// `config_ptr`/`config_len` must describe a valid slice (or be null+0).
/// `dart_api_data` must be the pointer returned by `NativeApi.initializeApiDLData`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ai_debug_init(
    dart_api_data: *mut std::ffi::c_void,
    dart_port: i64,
    config_ptr: *const u8,
    config_len: usize,
) -> ByteBuffer {
    TRACING_INIT.call_once(crate::logs::init_tracing);

    init_dart_api(dart_api_data);
    EVENTS.set_port(dart_port);

    // Parse config (app_id etc.) — stubbed: assume UTF-8 JSON for now.
    let config: serde_json::Value = if !config_ptr.is_null() && config_len > 0 {
        let slice = std::slice::from_raw_parts(config_ptr, config_len);
        serde_json::from_slice(slice).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };
    let app_id = config
        .get("appId")
        .and_then(|v| v.as_str())
        .unwrap_or("flutter_app")
        .to_string();
    let bind_port: u16 = config
        .get("port")
        .and_then(|v| v.as_u64())
        .map(|n| n as u16)
        .unwrap_or(9999);

    // Spawn the HTTP server asynchronously; return immediately so the caller
    // (Dart UI thread) is never blocked. The bind itself is usually < 10 ms
    // but on iOS we've seen sandbox-related stalls — never block the app.
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], bind_port));
    let app_id_clone = app_id.clone();
    RUNTIME.spawn(async move {
        match crate::server::serve(addr).await {
            Ok(a) => {
                let _ = crate::mdns::advertise(&app_id_clone, a.port());
                tracing::info!(addr = %a, app_id = %app_id_clone, "ai_debug server online");
            }
            Err(e) => tracing::error!(error = %e, "ai_debug server failed to bind"),
        }
    });

    let init_json =
        serde_json::json!({ "ok": true, "host": "0.0.0.0", "port": bind_port, "async": true });
    ByteBuffer::from_vec(init_json.to_string().into_bytes())
}

/// Dart pushes a `ToRust` envelope; returns a (possibly empty) ack envelope.
///
/// # Safety
/// `ptr` + `len` must describe a valid slice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ai_debug_send(ptr: *const u8, len: usize) -> ByteBuffer {
    if ptr.is_null() || len == 0 {
        return ByteBuffer::empty();
    }
    let slice = std::slice::from_raw_parts(ptr, len);
    let envelope = match ToRust::decode(slice) {
        Ok(e) => e,
        Err(e) => {
            tracing::warn!(error = %e, "ai_debug_send: failed to decode ToRust envelope");
            return ByteBuffer::empty();
        }
    };

    match envelope.kind {
        Some(to_rust::Kind::Register(reg)) => handle_register(reg),
        Some(to_rust::Kind::Unregister(u)) => handle_unregister(u),
        Some(to_rust::Kind::ToolResult(r)) => { handle_tool_result(r); ByteBuffer::empty() }
        Some(to_rust::Kind::DartLog(l)) => { LOGS.push(l); ByteBuffer::empty() }
        Some(to_rust::Kind::Shutdown(_)) => {
            EVENTS.disconnect();
            ByteBuffer::empty()
        }
        None => ByteBuffer::empty(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ai_debug_shutdown() {
    EVENTS.disconnect();
}

// ---- handlers ----------------------------------------------------------------

fn handle_register(reg: RegisterTool) -> ByteBuffer {
    let spec = ToolSpec {
        name: reg.name.clone(),
        description: reg.description,
        input_schema_json: reg.input_schema_json,
        output_schema_json: reg.output_schema_json,
        streaming: reg.streaming,
    };
    let inserted = TOOLS.insert(spec);
    tracing::info!(tool = %reg.name, inserted, "tool registered");
    ByteBuffer::empty()
}

fn handle_unregister(u: UnregisterTool) -> ByteBuffer {
    let removed = TOOLS.remove(&u.name);
    tracing::info!(tool = %u.name, removed, "tool unregistered");
    ByteBuffer::empty()
}

fn handle_tool_result(r: ToolResult) {
    let tx = {
        let mut p = PENDING.lock();
        p.remove(&r.request_id)
    };
    let Some(tx) = tx else {
        tracing::warn!(req = r.request_id, "tool result for unknown request");
        return;
    };
    let _ = tx.send(crate::state::PendingResult {
        success: r.success,
        error: r.error,
        result_json: match r.result_json { Some(s) if !s.is_empty() => Some(s), _ => None },
        binary: r.binary,
        binary_mime: r.binary_mime,
    });
}

