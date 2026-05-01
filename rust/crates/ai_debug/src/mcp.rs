//! rmcp-backed MCP server.
//!
//! Implements `ServerHandler` manually because tools are registered
//! dynamically from Dart at runtime. Each built-in and each registered
//! tool appears in `tools/list`; `tools/call` either handles it locally
//! (built-ins) or round-trips to Dart via the NativeEventPort.

use crate::client;
use crate::pb::log_record::Level as PbLevel;
use crate::state::{LOGS, TOOLS};
use rmcp::handler::server::ServerHandler;
use rmcp::model::{
    CallToolRequestParams, CallToolResult, Content, ListToolsResult, PaginatedRequestParams,
    ServerCapabilities, ServerInfo, Tool,
};
use rmcp::service::RequestContext;
use rmcp::{ErrorData as McpError, RoleServer};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

const DART_QUERY_TIMEOUT: Duration = Duration::from_secs(3);
const DART_INVOKE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Default)]
pub struct AiDebugServer;

impl AiDebugServer {
    pub fn new() -> Self { Self }

    fn builtin_tools() -> Vec<Tool> {
        let tail_schema: serde_json::Map<String, Value> = serde_json::from_value(json!({
            "type": "object",
            "properties": {
                "limit":    { "type": "integer", "default": 200, "minimum": 1, "maximum": 2000 },
                "level":    { "type": "string",  "enum": ["trace","debug","info","warn","error"] },
                "grep":     { "type": "string",  "description": "Substring filter on message" },
                "source":   { "type": "string",  "enum": ["rust","dart"], "description": "Restrict to one source" },
                "since_ms": { "type": "integer", "description": "Unix ms; records older are dropped" }
            },
            "additionalProperties": false
        }))
        .unwrap();

        let empty_schema: serde_json::Map<String, Value> = serde_json::from_value(json!({
            "type": "object",
            "properties": {},
            "additionalProperties": false
        }))
        .unwrap();

        vec![
            Tool::new(
                "tail_logs",
                "Return a merged Rust + Dart log tail, newest last. Source-tagged per record.",
                Arc::new(tail_schema),
            ),
            Tool::new(
                "list_apps",
                "List currently connected app instances (by appId) served by this ai_debug server.",
                Arc::new(empty_schema),
            ),
        ]
    }

    fn dynamic_tools() -> Vec<Tool> {
        TOOLS
            .list()
            .into_iter()
            .map(|spec| {
                let schema: serde_json::Map<String, Value> =
                    serde_json::from_str(&spec.input_schema_json).unwrap_or_default();
                let mut tool = Tool::new(spec.name, spec.description, Arc::new(schema));
                if let Some(out) = spec
                    .output_schema_json
                    .as_ref()
                    .and_then(|s| serde_json::from_str::<serde_json::Map<String, Value>>(s).ok())
                {
                    tool.output_schema = Some(Arc::new(out));
                }
                tool
            })
            .collect()
    }

    async fn call_tail_logs(args: Value) -> Result<CallToolResult, McpError> {
        let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
        let limit = limit.min(2000);
        let level = args.get("level").and_then(Value::as_str).and_then(parse_level);
        let grep = args.get("grep").and_then(Value::as_str).map(String::from);
        let since_ms = args.get("since_ms").and_then(Value::as_i64);
        let source = args.get("source").and_then(Value::as_str).map(|s| s.to_ascii_lowercase());

        let want_rust = source.as_deref().is_none_or(|s| s == "rust");
        let want_dart = source.as_deref().is_none_or(|s| s == "dart");

        let mut merged: Vec<Value> = Vec::with_capacity(limit * 2);
        if want_rust {
            for r in LOGS.tail(limit, level, grep.as_deref()) {
                if let Some(since) = since_ms {
                    if r.timestamp_ms < since { continue; }
                }
                merged.push(log_to_json(&r));
            }
        }
        if want_dart {
            if let Ok(res) = client::query_dart_logs(
                limit as i32,
                level.map(|l| l as i32),
                grep.clone(),
                since_ms,
                DART_QUERY_TIMEOUT,
            )
            .await
            {
                if res.success {
                    if let Some(body) = res.result_json.as_deref() {
                        if let Ok(val) = serde_json::from_str::<Value>(body) {
                            if let Some(arr) = val.get("logs").and_then(|v| v.as_array()) {
                                merged.extend(arr.iter().cloned());
                            }
                        }
                    }
                }
            }
        }
        merged.sort_by_key(|v| v.get("timestamp_ms").and_then(|n| n.as_i64()).unwrap_or(0));
        if merged.len() > limit {
            let drop_n = merged.len() - limit;
            merged.drain(..drop_n);
        }
        Ok(CallToolResult::structured(json!({ "logs": merged })))
    }

    async fn call_list_apps() -> Result<CallToolResult, McpError> {
        // Phase 1: only this process hosts the server, so "apps" is a single entry.
        Ok(CallToolResult::structured(json!({
            "apps": [{ "host": "0.0.0.0", "port": 9999 }]
        })))
    }

    async fn call_dart(name: &str, args: Value) -> Result<CallToolResult, McpError> {
        let args_json = serde_json::to_string(&args).unwrap_or_else(|_| "null".into());
        match client::invoke_dart_tool(name, &args_json, DART_INVOKE_TIMEOUT).await {
            Ok(res) if res.success => {
                if let Some(body) = res.result_json.as_deref() {
                    if let Ok(v) = serde_json::from_str::<Value>(body) {
                        return Ok(CallToolResult::structured(v));
                    }
                }
                Ok(CallToolResult::success(vec![]))
            }
            Ok(res) => {
                let msg = res.error.unwrap_or_else(|| "tool returned error".into());
                Ok(CallToolResult::error(vec![Content::text(msg)]))
            }
            Err(e) => Ok(CallToolResult::error(vec![Content::text(e.to_string())])),
        }
    }
}

impl ServerHandler for AiDebugServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(
                "Flutter app debug bridge. Built-in tools: tail_logs, list_apps. \
                 App-registered tools appear dynamically — call list_tools to see current set.",
            )
    }

    async fn list_tools(
        &self,
        _req: Option<PaginatedRequestParams>,
        _ctx: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        let mut tools = Self::builtin_tools();
        tools.extend(Self::dynamic_tools());
        Ok(ListToolsResult {
            tools,
            next_cursor: None,
            meta: None,
        })
    }

    async fn call_tool(
        &self,
        req: CallToolRequestParams,
        _ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        let name = req.name.as_ref();
        let args = req.arguments.map(Value::Object).unwrap_or(Value::Null);
        match name {
            "tail_logs" => Self::call_tail_logs(args).await,
            "list_apps" => Self::call_list_apps().await,
            other => {
                if TOOLS.get(other).is_some() {
                    Self::call_dart(other, args).await
                } else {
                    Err(McpError::invalid_params(
                        format!("unknown tool: {other}"),
                        None,
                    ))
                }
            }
        }
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
