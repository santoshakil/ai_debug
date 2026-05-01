//! Rust-side helper for invoking Dart handlers over the NativeEventPort
//! and awaiting a `ToolResult` envelope keyed by request_id.

use crate::pb::{to_dart, QueryDartLogs, ToDart, ToolInvoke};
use crate::state::{next_request_id, PendingResult, EVENTS, PENDING, RUNTIME};
use prost::Message;
use std::time::Duration;
use tokio::sync::oneshot;

#[derive(Debug, thiserror::Error)]
pub enum CallError {
    #[error("dart port not connected")]
    NotConnected,
    #[error("timeout waiting for dart response")]
    Timeout,
    #[error("dart returned error: {0}")]
    Remote(String),
    #[error("dart response was empty")]
    Empty,
}

/// Send a ToDart envelope; caller is responsible for registering a oneshot
/// matching `request_id` *before* calling if it expects a reply.
fn send_to_dart(env: ToDart) -> Result<(), CallError> {
    if !EVENTS.is_connected() {
        return Err(CallError::NotConnected);
    }
    let bytes = env.encode_to_vec();
    if !EVENTS.send_envelope(bytes) {
        return Err(CallError::NotConnected);
    }
    Ok(())
}

async fn await_result(req_id: i64, timeout: Duration) -> Result<PendingResult, CallError> {
    let (tx, rx) = oneshot::channel();
    PENDING.lock().insert(req_id, tx);

    match tokio::time::timeout(timeout, rx).await {
        Ok(Ok(r)) => Ok(r),
        Ok(Err(_)) => Err(CallError::Empty),
        Err(_) => {
            PENDING.lock().remove(&req_id);
            Err(CallError::Timeout)
        }
    }
}

pub async fn invoke_dart_tool(
    name: &str,
    args_json: &str,
    timeout: Duration,
) -> Result<PendingResult, CallError> {
    let req_id = next_request_id();
    let env = ToDart {
        kind: Some(to_dart::Kind::Invoke(ToolInvoke {
            request_id: req_id,
            name: name.to_string(),
            args_json: args_json.to_string(),
            streaming: false,
        })),
    };
    send_to_dart(env)?;
    await_result(req_id, timeout).await
}

pub async fn query_dart_logs(
    limit: i32,
    min_level: Option<i32>,
    grep: Option<String>,
    since_ms: Option<i64>,
    timeout: Duration,
) -> Result<PendingResult, CallError> {
    let req_id = next_request_id();
    let env = ToDart {
        kind: Some(to_dart::Kind::QueryDartLogs(QueryDartLogs {
            request_id: req_id,
            limit,
            since_ms,
            min_level,
            grep,
        })),
    };
    send_to_dart(env)?;
    await_result(req_id, timeout).await
}

/// Block the current thread until the future completes on the ai_debug runtime.
/// Only use from sync axum handlers that already return futures;
/// async handlers should await `query_dart_logs` directly.
#[allow(dead_code)]
pub fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    RUNTIME.block_on(fut)
}
