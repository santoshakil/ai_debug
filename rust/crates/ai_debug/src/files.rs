//! Streaming file download over HTTP — `GET /api/file?path=…` and `HEAD /api/file?path=…`.
//!
//! Uses `tokio::fs::File` + `tokio_util::io::ReaderStream` so the bytes flow
//! kernel → socket without ever entering the Dart heap. HTTP `Range` is
//! honored for resume + parallel-chunk downloads.
//!
//! Path policy (matches the rest of the bridge):
//!   - must be absolute
//!   - must not contain `..` (path-traversal sanity check)
//!   - must point to a regular file
//!
//! The bridge is intended for debug builds only. Anything that can reach the
//! port can read any file the app process can read. This is consistent with
//! the existing `fs_read_text` / `fs_read_bytes` Dart tools.

use axum::body::Body;
use axum::extract::Query;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use serde::Deserialize;
use std::path::{Component, PathBuf};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio_util::io::ReaderStream;

#[derive(Debug, Deserialize)]
pub struct FileQuery {
    pub path: String,
}

type FileError = (StatusCode, String);

pub async fn head_file(Query(q): Query<FileQuery>) -> Result<Response, FileError> {
    let path = validate_path(&q.path)?;
    let meta = tokio::fs::metadata(&path)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, format!("stat: {e}")))?;
    if !meta.is_file() {
        return Err((StatusCode::BAD_REQUEST, "not a regular file".into()));
    }
    let filename = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file");
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_LENGTH, meta.len())
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{filename}\""),
        )
        .body(Body::empty())
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("build: {e}")))
}

pub async fn get_file(
    Query(q): Query<FileQuery>,
    headers: HeaderMap,
) -> Result<Response, FileError> {
    let path = validate_path(&q.path)?;
    let meta = tokio::fs::metadata(&path)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, format!("stat: {e}")))?;
    if !meta.is_file() {
        return Err((StatusCode::BAD_REQUEST, "not a regular file".into()));
    }
    let total = meta.len();

    let range_str = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let (start, end) = match range_str.as_deref() {
        Some(r) => parse_range(r, total)
            .ok_or_else(|| (StatusCode::RANGE_NOT_SATISFIABLE, format!("bad Range: {r}")))?,
        None => {
            if total == 0 {
                (0u64, 0u64)
            } else {
                (0u64, total - 1)
            }
        }
    };
    let length = if total == 0 {
        0
    } else {
        end - start + 1
    };

    let mut file = File::open(&path)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("open: {e}")))?;
    if start > 0 {
        file.seek(SeekFrom::Start(start))
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("seek: {e}")))?;
    }
    let limited = file.take(length);
    let stream = ReaderStream::new(limited);
    let body = Body::from_stream(stream);

    let filename = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file");
    let status = if range_str.is_some() {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };

    let mut builder = Response::builder()
        .status(status)
        .header(header::CONTENT_LENGTH, length)
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{filename}\""),
        );

    if range_str.is_some() {
        builder = builder.header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{total}"),
        );
    }

    builder
        .body(body)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("build: {e}")))
}

fn validate_path(s: &str) -> Result<PathBuf, FileError> {
    let p = PathBuf::from(s);
    if !p.is_absolute() {
        return Err((StatusCode::BAD_REQUEST, "path must be absolute".into()));
    }
    if p.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err((StatusCode::BAD_REQUEST, "path may not contain ..".into()));
    }
    Ok(p)
}

/// Parse an HTTP Range header value of the forms:
///   `bytes=START-END`      explicit range, inclusive
///   `bytes=START-`         from START to EOF
///   `bytes=-SUFFIX`        last SUFFIX bytes
/// Returns `(start, end)` clamped to file size, or `None` on malformed input.
fn parse_range(value: &str, total: u64) -> Option<(u64, u64)> {
    let r = value.strip_prefix("bytes=")?;
    let (start_str, end_str) = r.split_once('-')?;
    if total == 0 {
        return None;
    }
    let last = total - 1;
    if start_str.is_empty() {
        let n: u64 = end_str.parse().ok()?;
        if n == 0 {
            return None;
        }
        let n = n.min(total);
        return Some((total - n, last));
    }
    let start: u64 = start_str.parse().ok()?;
    if start > last {
        return None;
    }
    let end = if end_str.is_empty() {
        last
    } else {
        end_str.parse::<u64>().ok()?.min(last)
    };
    if end < start {
        return None;
    }
    Some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_range_explicit() {
        assert_eq!(parse_range("bytes=0-99", 1000), Some((0, 99)));
        assert_eq!(parse_range("bytes=500-999", 1000), Some((500, 999)));
    }

    #[test]
    fn parse_range_open_ended() {
        assert_eq!(parse_range("bytes=500-", 1000), Some((500, 999)));
    }

    #[test]
    fn parse_range_suffix() {
        assert_eq!(parse_range("bytes=-100", 1000), Some((900, 999)));
        assert_eq!(parse_range("bytes=-2000", 1000), Some((0, 999)));
    }

    #[test]
    fn parse_range_clamps_end() {
        assert_eq!(parse_range("bytes=0-99999", 1000), Some((0, 999)));
    }

    #[test]
    fn parse_range_rejects_invalid() {
        assert_eq!(parse_range("bytes=999-0", 1000), None);
        assert_eq!(parse_range("bytes=2000-3000", 1000), None);
        assert_eq!(parse_range("bytes=-0", 1000), None);
        assert_eq!(parse_range("kilometers=0-99", 1000), None);
        assert_eq!(parse_range("bytes=0-99", 0), None);
    }
}
