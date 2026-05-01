//! mDNS advertisement for `_ai-debug._tcp.local.` so clients can discover running apps.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicBool, Ordering};

static ADVERTISED: AtomicBool = AtomicBool::new(false);

pub fn advertise(app_id: &str, port: u16) -> anyhow::Result<()> {
    if ADVERTISED.swap(true, Ordering::AcqRel) {
        tracing::debug!("mdns already advertised");
        return Ok(());
    }

    let daemon = mdns_sd::ServiceDaemon::new()?;
    let host = hostname().unwrap_or_else(|| "localhost".into());
    let ips: Vec<IpAddr> = local_ipv4s().into_iter().map(IpAddr::V4).collect();

    let mut props: HashMap<String, String> = HashMap::new();
    props.insert("appId".into(), app_id.into());
    props.insert("version".into(), env!("CARGO_PKG_VERSION").into());

    let service = mdns_sd::ServiceInfo::new(
        "_ai-debug._tcp.local.",
        app_id,
        &format!("{host}.local."),
        &ips[..],
        port,
        Some(props),
    )?;

    daemon.register(service)?;
    tracing::info!(app_id, port, "mdns advertised");

    // Keep the daemon alive for the life of the process.
    std::mem::forget(daemon);
    Ok(())
}

fn local_ipv4s() -> Vec<Ipv4Addr> {
    vec![Ipv4Addr::UNSPECIFIED]
}

fn hostname() -> Option<String> {
    let mut buf = [0u8; 256];
    let ret = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut _, buf.len()) };
    if ret != 0 {
        return None;
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    std::str::from_utf8(&buf[..end]).ok().map(|s| s.to_string())
}
