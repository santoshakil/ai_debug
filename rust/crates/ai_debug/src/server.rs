//! HTTP API for Phase 1.5.
//!
//! Endpoints:
//!   GET  /healthz                  — plaintext liveness
//!   GET  /api/tools                — list of registered tools
//!   GET  /api/logs                 — merged Rust + Dart log tail
//!   POST /api/cmd/:name            — invoke a Dart-registered tool (body = JSON args)
//!
//! Phase 2 will wrap these as MCP JSON-RPC via `rmcp`.

use crate::client;
use crate::pb::log_record::Level as PbLevel;
use crate::state::{LOGS, TOOLS};
use axum::{
    extract::{Path, Query},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::time::Duration;
use tower_http::cors::CorsLayer;

const DART_QUERY_TIMEOUT: Duration = Duration::from_secs(3);
const DART_INVOKE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Deserialize, Default)]
pub struct TailLogsQuery {
    pub limit: Option<usize>,
    pub level: Option<String>,
    pub grep: Option<String>,
    pub source: Option<String>, // "rust" | "dart" | (none = merged)
    pub since_ms: Option<i64>,
}

pub async fn serve(bind: SocketAddr) -> anyhow::Result<SocketAddr> {
    use rmcp::transport::streamable_http_server::{
        session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
    };

    let mcp_service: StreamableHttpService<crate::mcp::AiDebugServer, LocalSessionManager> =
        StreamableHttpService::new(
            || Ok(crate::mcp::AiDebugServer::new()),
            Default::default(),
            StreamableHttpServerConfig::default(),
        );

    let app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/api/tools", get(list_tools))
        .route("/api/logs", get(tail_logs))
        .route("/api/cmd/{name}", post(invoke_cmd))
        .route(
            "/api/file",
            get(crate::files::get_file).head(crate::files::head_file),
        )
        .nest_service("/mcp", mcp_service)
        .layer(CorsLayer::permissive());

    let listener = tokio::net::TcpListener::bind(bind).await?;
    let actual = listener.local_addr()?;
    tracing::info!(addr = %actual, "ai_debug server listening");

    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            tracing::error!(error = %e, "axum serve exited");
        }
    });

    Ok(actual)
}

async fn list_tools() -> Json<Value> {
    let tools: Vec<_> = TOOLS
        .list()
        .into_iter()
        .map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "inputSchema": serde_json::from_str::<Value>(&t.input_schema_json).unwrap_or(Value::Null),
                "streaming": t.streaming,
            })
        })
        .collect();
    Json(json!({ "tools": tools }))
}

async fn tail_logs(Query(q): Query<TailLogsQuery>) -> Json<Value> {
    let limit = q.limit.unwrap_or(200).min(2000);
    let min = q.level.as_deref().and_then(parse_level);
    let source = q.source.as_deref().map(|s| s.to_ascii_lowercase());
    let want_rust = source.as_deref().is_none_or(|s| s == "rust");
    let want_dart = source.as_deref().is_none_or(|s| s == "dart");

    let mut merged: Vec<Value> = Vec::with_capacity(limit * 2);

    if want_rust {
        for r in LOGS.tail(limit, min, q.grep.as_deref()) {
            if let Some(since) = q.since_ms {
                if r.timestamp_ms < since {
                    continue;
                }
            }
            merged.push(log_to_json(&r));
        }
    }

    if want_dart {
        match client::query_dart_logs(
            limit as i32,
            min.map(|l| l as i32),
            q.grep.clone(),
            q.since_ms,
            DART_QUERY_TIMEOUT,
        )
        .await
        {
            Ok(res) if res.success => {
                if let Some(body) = res.result_json.as_deref() {
                    if let Ok(val) = serde_json::from_str::<Value>(body) {
                        if let Some(arr) = val.get("logs").and_then(|v| v.as_array()) {
                            merged.extend(arr.iter().cloned());
                        }
                    }
                }
            }
            Ok(res) => tracing::warn!(err = ?res.error, "dart log query returned error"),
            Err(client::CallError::NotConnected) => {
                // Dart side hasn't connected yet — fine, emit only Rust.
            }
            Err(e) => tracing::warn!(error = %e, "dart log query failed"),
        }
    }

    merged.sort_by_key(|v| v.get("timestamp_ms").and_then(|n| n.as_i64()).unwrap_or(0));
    if merged.len() > limit {
        let drop_n = merged.len() - limit;
        merged.drain(..drop_n);
    }

    Json(json!({ "logs": merged }))
}

async fn invoke_cmd(Path(name): Path<String>, body: Option<Json<Value>>) -> (StatusCode, Json<Value>) {
    let args = body.map(|Json(v)| v).unwrap_or(Value::Null);
    let args_json = serde_json::to_string(&args).unwrap_or_else(|_| "null".into());

    if TOOLS.get(&name).is_none() {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": format!("unknown tool: {name}") })));
    }

    match client::invoke_dart_tool(&name, &args_json, DART_INVOKE_TIMEOUT).await {
        Ok(res) => {
            let mut out = json!({
                "success": res.success,
            });
            if let Some(err) = res.error {
                out["error"] = Value::String(err);
            }
            if let Some(json_body) = res.result_json.as_deref() {
                if let Ok(v) = serde_json::from_str::<Value>(json_body) {
                    out["result"] = v;
                } else {
                    out["result"] = Value::String(json_body.into());
                }
            }
            if let Some(bin) = res.binary {
                use base64::Engine;
                out["binary_b64"] = Value::String(base64::engine::general_purpose::STANDARD.encode(bin));
                if let Some(mime) = res.binary_mime {
                    out["binary_mime"] = Value::String(mime);
                }
            }
            (StatusCode::OK, Json(out))
        }
        Err(e) => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(json!({ "success": false, "error": e.to_string() })),
        ),
    }
}

fn parse_level(s: &str) -> Option<PbLevel> {
    match s.to_ascii_lowercase().as_str() {
        "trace" => Some(PbLevel::Trace),
        "debug" => Some(PbLevel::Debug),
        "info" => Some(PbLevel::Info),
        "warn" | "warning" => Some(PbLevel::Warn),
        "error" => Some(PbLevel::Error),
        _ => None,
    }
}

fn log_to_json(r: &crate::pb::LogRecord) -> Value {
    json!({
        "timestamp_ms": r.timestamp_ms,
        "source": if r.source == 0 { "rust" } else { "dart" },
        "level": match r.level {
            0 => "trace", 1 => "debug", 2 => "info", 3 => "warn", 4 => "error", _ => "?",
        },
        "logger": r.logger,
        "message": r.message,
        "error": r.error,
        "stack": r.stack,
        "fields": r.fields,
    })
}
