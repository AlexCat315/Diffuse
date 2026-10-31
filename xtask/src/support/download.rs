//! Downloads a pinned artifact and verifies its SHA-256 before use. A cached
//! file that already matches the digest is reused without network access.
//!
//! The crate has no TLS dependency, so the transfer itself is delegated to the
//! platform `curl` executable (present on macOS, Windows 10+ and every Linux
//! distribution Cove targets). Redirect resolution, digest verification and
//! atomic publication stay in Rust, exactly as the Swift implementation kept
//! them around `URLSession`.

use super::files;
use super::sha256;
use super::shell;
use super::terminal::{Terminal, ToolError};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Resolves `remote` after redirects using a HEAD request, without a body.
/// Used to read GitHub's `/releases/latest` pointer without the API rate limit
/// that applies to api.github.com.
pub fn redirected_url(remote: &str) -> Result<String, ToolError> {
    require_https(remote)?;
    let environment = environment();
    let output = shell::output(
        &[
            "curl".into(),
            "--fail".into(),
            "--location".into(),
            "--silent".into(),
            "--show-error".into(),
            "--head".into(),
            "--output".into(),
            null_device().into(),
            "--write-out".into(),
            "%{url_effective}".into(),
            remote.into(),
        ],
        None,
        &environment,
        true,
    )
    .map_err(|error| ToolError::message(format!("HTTP request for {remote} failed: {error}")))?;
    let url = output.trim().to_string();
    if url.is_empty() {
        return Err(ToolError::message(format!(
            "Redirect did not complete: {remote}"
        )));
    }
    Ok(url)
}

/// Downloads metadata beside `destination`, then publishes it atomically.
pub fn metadata(from: &str, to: &Path) -> Result<(), ToolError> {
    require_https(from)?;
    if let Some(parent) = to.parent() {
        files::directory(parent).map_err(io_error)?;
    }
    let downloaded = fetch(from, to)?;
    let result = files::replace(&downloaded, to).map_err(io_error);
    if result.is_err() {
        let _ = files::remove(&downloaded);
    }
    result
}

/// Verifies the digest of an existing file.
pub fn verify(file: &Path, expected: &str) -> Result<(), ToolError> {
    let actual = sha256::hex_file(file).map_err(io_error)?;
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(ToolError::message(format!(
            "SHA-256 mismatch for {}: expected {expected}, got {actual}",
            file.file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default()
        )));
    }
    Ok(())
}

/// Downloads `remote` to `destination` unless the cached file already matches.
pub fn file(from: &str, to: &Path, sha256: &str) -> Result<(), ToolError> {
    if to.is_file()
        && let Ok(actual) = sha256::hex_file(to)
        && actual.eq_ignore_ascii_case(sha256)
    {
        return Ok(());
    }
    if let Some(parent) = to.parent() {
        files::directory(parent).map_err(io_error)?;
    }
    Terminal::info(&format!("Downloading {from}"));
    let downloaded = fetch(from, to)?;
    let result = (|| {
        verify(&downloaded, sha256)?;
        files::replace(&downloaded, to).map_err(io_error)
    })();
    let _ = files::remove(&downloaded);
    result
}

fn fetch(remote: &str, destination: &Path) -> Result<PathBuf, ToolError> {
    let environment = environment();
    let parent = destination
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    files::directory(&parent).map_err(io_error)?;
    let staging = parent.join(format!(".cove-download-{}", unique_token()));
    let output = shell::output(
        &[
            "curl".into(),
            "--fail".into(),
            "--location".into(),
            "--silent".into(),
            "--show-error".into(),
            "--output".into(),
            staging.display().to_string(),
            remote.into(),
        ],
        None,
        &environment,
        true,
    );
    match output {
        Ok(_) => {
            if !staging.is_file() {
                return Err(ToolError::message(format!("No data for {remote}")));
            }
            Ok(staging)
        }
        Err(error) => {
            let _ = files::remove(&staging);
            Err(ToolError::message(format!("{remote}: {error}")))
        }
    }
}

fn require_https(remote: &str) -> Result<(), ToolError> {
    if remote.starts_with("https://") {
        Ok(())
    } else {
        Err(ToolError::message("Metadata requires HTTPS"))
    }
}

fn null_device() -> &'static str {
    if cfg!(windows) { "NUL" } else { "/dev/null" }
}

fn environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

fn unique_token() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    format!(
        "{:x}{:x}{:x}",
        std::process::id(),
        nanos,
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}
