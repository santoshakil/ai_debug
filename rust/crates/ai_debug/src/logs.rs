//! In-memory log ring buffer + tracing Layer.

use crate::pb::log_record::{Level as PbLevel, Source as PbSource};
use crate::pb::LogRecord as PbLogRecord;
use parking_lot::Mutex;
use std::collections::VecDeque;
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

const CAP: usize = 2000;

pub struct LogBuffer {
    inner: Mutex<VecDeque<PbLogRecord>>,
}

impl LogBuffer {
    pub fn new() -> Self {
        Self { inner: Mutex::new(VecDeque::with_capacity(CAP)) }
    }

    pub fn push(&self, record: PbLogRecord) {
        let mut b = self.inner.lock();
        if b.len() >= CAP { b.pop_front(); }
        b.push_back(record);
    }

    /// Return most-recent-first, up to `limit`. Empty `min_level` = all.
    pub fn tail(&self, limit: usize, min_level: Option<PbLevel>, grep: Option<&str>) -> Vec<PbLogRecord> {
        let b = self.inner.lock();
        b.iter()
            .rev()
            .filter(|r| {
                min_level.as_ref().is_none_or(|lvl| r.level >= *lvl as i32)
                    && grep.is_none_or(|g| r.message.contains(g))
            })
            .take(limit)
            .cloned()
            .collect()
    }
}

impl Default for LogBuffer {
    fn default() -> Self { Self::new() }
}

/// tracing Layer: every event becomes a LogRecord pushed into the global LOGS buffer.
pub struct RingBufferLayer;

impl<S> Layer<S> for RingBufferLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let level = match *metadata.level() {
            tracing::Level::TRACE => PbLevel::Trace,
            tracing::Level::DEBUG => PbLevel::Debug,
            tracing::Level::INFO => PbLevel::Info,
            tracing::Level::WARN => PbLevel::Warn,
            tracing::Level::ERROR => PbLevel::Error,
        };

        let mut msg = String::new();
        let mut fields: std::collections::HashMap<String, String> = Default::default();
        event.record(&mut FieldVisitor { msg: &mut msg, fields: &mut fields });

        let rec = PbLogRecord {
            timestamp_ms: chrono::Utc::now().timestamp_millis(),
            source: PbSource::Rust as i32,
            level: level as i32,
            logger: metadata.target().to_string(),
            message: msg,
            error: None,
            stack: None,
            fields,
        };
        crate::state::LOGS.push(rec);
    }
}

struct FieldVisitor<'a> {
    msg: &'a mut String,
    fields: &'a mut std::collections::HashMap<String, String>,
}

impl<'a> tracing::field::Visit for FieldVisitor<'a> {
    fn record_debug(&mut self, f: &tracing::field::Field, v: &dyn std::fmt::Debug) {
        let s = format!("{v:?}");
        if f.name() == "message" {
            *self.msg = s;
        } else {
            self.fields.insert(f.name().to_string(), s);
        }
    }
    fn record_str(&mut self, f: &tracing::field::Field, v: &str) {
        if f.name() == "message" {
            *self.msg = v.to_string();
        } else {
            self.fields.insert(f.name().to_string(), v.to_string());
        }
    }
}

pub fn init_tracing() {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let filter = tracing_subscriber::EnvFilter::try_from_env("AI_DEBUG_LOG")
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,ai_debug=debug"));

    // Idempotent: ignore if a subscriber is already installed (e.g., integrating app already did this).
    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(RingBufferLayer)
        .try_init();
}
