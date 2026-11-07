//! `SourceDownload.swift` — bounded, retryable, checksum-verified downloads.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::support::download;
use crate::support::files;
use crate::support::sha256;
use crate::support::shell;
use crate::support::terminal::{Terminal, ToolError};

static TRANSFER_ID: AtomicU64 = AtomicU64::new(0);

pub enum SourceDownload {}

impl SourceDownload {
    /// Fetches a single mirror with the default transfer.
    pub fn fetch(
        remote: &str,
        destination: &Path,
        sha256_digest: &str,
        environment: &BTreeMap<String, String>,
    ) -> Result<(), ToolError> {
        Self::fetch_with(
            &[remote.to_string()],
            destination,
            sha256_digest,
            environment,
            default_transfer,
        )
    }

    /// The multi-mirror overload with the default transfer.
    pub fn fetch_many(
        remotes: &[String],
        destination: &Path,
        sha256_digest: &str,
        environment: &BTreeMap<String, String>,
    ) -> Result<(), ToolError> {
        Self::fetch_with(
            remotes,
            destination,
            sha256_digest,
            environment,
            default_transfer,
        )
    }

    /// Fetches from every mirror in order, accepting the first one whose
    /// digest matches. `transfer` is injectable so the retry policy can be
    /// exercised without network access.
    pub fn fetch_with<F>(
        remotes: &[String],
        destination: &Path,
        sha256_digest: &str,
        environment: &BTreeMap<String, String>,
        transfer: F,
    ) -> Result<(), ToolError>
    where
        F: Fn(&[String], &BTreeMap<String, String>) -> Result<(), ToolError>,
    {
        if remotes.is_empty() || !remotes.iter().all(|remote| remote.starts_with("https://")) {
            return Err(ToolError::message("FFmpeg sources require HTTPS mirrors"));
        }
        if let Ok(actual) = sha256::hex_file(destination)
            && actual.eq_ignore_ascii_case(sha256_digest)
        {
            return Ok(());
        }
        let Some(curl) = shell::executable("curl", environment) else {
            return Err(ToolError::message(
                "curl is required to download FFmpeg sources",
            ));
        };
        if let Some(parent) = destination.parent() {
            files::directory(parent).map_err(io_error)?;
        }
        let mut failures: Vec<String> = Vec::new();
        for remote in remotes {
            let staging = destination
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join(staging_name());
            // Swift's `defer { try? Fs.remove(staging) }` runs on every path,
            // including the early returns and propagated errors below.
            let _cleanup = RemoveOnDrop(staging.clone());
            Terminal::info(&format!("Downloading {remote}"));
            let result = (|| -> Result<(), ToolError> {
                transfer(
                    &[
                        curl.display().to_string(),
                        "--fail".into(),
                        "--show-error".into(),
                        "--location".into(),
                        "--ipv4".into(),
                        "--proto".into(),
                        "=https".into(),
                        "--proto-redir".into(),
                        "=https".into(),
                        "--connect-timeout".into(),
                        "20".into(),
                        "--max-time".into(),
                        "180".into(),
                        "--retry".into(),
                        "4".into(),
                        "--retry-all-errors".into(),
                        "--retry-delay".into(),
                        "2".into(),
                        "--retry-max-time".into(),
                        "600".into(),
                        "--output".into(),
                        staging.display().to_string(),
                        remote.clone(),
                    ],
                    environment,
                )?;
                download::verify(&staging, sha256_digest)?;
                files::replace(&staging, destination).map_err(io_error)
            })();
            match result {
                Ok(()) => return Ok(()),
                Err(error) => failures.push(format!("{remote}: {error}")),
            }
        }
        Err(ToolError::message(format!(
            "FFmpeg source download failed from every mirror:\n{}",
            failures.join("\n")
        )))
    }
}

fn default_transfer(
    command: &[String],
    environment: &BTreeMap<String, String>,
) -> Result<(), ToolError> {
    shell::inherit(command, None, environment, None)
}

fn staging_name() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!(
        ".ffmpeg-download-{}-{}-{}",
        std::process::id(),
        nanos,
        TRANSFER_ID.fetch_add(1, Ordering::Relaxed)
    )
}

/// Mirrors `defer { try? Fs.remove(staging) }` — cleanup also runs when a
/// `?` unwinds out of the retry body.
struct RemoveOnDrop(PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = files::remove(&self.0);
    }
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}
