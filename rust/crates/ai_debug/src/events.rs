//! NativeEventPort: pushes `ToDart` events to the Dart side via irondash.
//!
//! Pattern lifted from pattern_h / proto2ffil.

use irondash_dart_ffi::{DartPort, DartValue};
use std::sync::atomic::{AtomicI64, Ordering};

/// Event discriminator (index 0 of the list sent to the Dart port).
#[repr(i32)]
#[derive(Copy, Clone, Debug)]
pub enum EventId {
    /// Full `ToDart` envelope (protobuf bytes in slot 1).
    Envelope = 0,
}

pub struct NativeEventPort {
    port: AtomicI64,
}

impl Default for NativeEventPort {
    fn default() -> Self {
        Self::new()
    }
}

impl NativeEventPort {
    pub const fn new() -> Self {
        Self { port: AtomicI64::new(0) }
    }

    pub fn set_port(&self, port: i64) {
        self.port.store(port, Ordering::Release);
        tracing::info!(port, "dart event port set");
    }

    pub fn get_port(&self) -> Option<DartPort> {
        let p = self.port.load(Ordering::Acquire);
        if p == 0 { None } else { Some(DartPort::new(p)) }
    }

    pub fn is_connected(&self) -> bool {
        self.port.load(Ordering::Acquire) != 0
    }

    pub fn disconnect(&self) {
        self.port.store(0, Ordering::Release);
        tracing::info!("dart event port disconnected");
    }

    /// Send a ToDart envelope (already-serialized prost bytes).
    pub fn send_envelope(&self, bytes: Vec<u8>) -> bool {
        if let Some(port) = self.get_port() {
            port.send(vec![
                DartValue::I32(EventId::Envelope as i32),
                DartValue::U8List(bytes),
            ])
        } else {
            tracing::warn!("dart port not set, event dropped");
            false
        }
    }
}

pub fn init_dart_api(data: *mut std::ffi::c_void) {
    // One-time init of Dart Native API for this process.
    irondash_dart_ffi::irondash_init_ffi(data);
}
