//! Verified upstream downloads, ported from
//! `Tools/Developer/Sources/Build/PluginStaging/Archive.swift`. Never execute
//! code from an unverified archive.

use crate::support::files;
use crate::support::shell;
use crate::support::terminal::ToolError;
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

pub struct SourceArchive;

impl SourceArchive {
    /// Downloads `url` into `cache`, verifies `checksum`, extracts it once and
    /// returns the single directory the archive contains.
    pub fn fetch(url: &str, checksum: &str, cache: &Path) -> Result<PathBuf, ToolError> {
        files::directory(cache).map_err(io_error)?;
        if !url.starts_with("https://") && !url.starts_with("http://") {
            return Err(ToolError::message(format!("Invalid archive URL: {url}")));
        }
        let file_name = url.rsplit('/').next().unwrap_or_default();
        let archive = cache.join(file_name);
        crate::support::download::file(url, &archive, checksum)?;

        let mut name = file_name.to_string();
        for suffix in [".tar.xz", ".tar.gz", ".zip"] {
            if let Some(stripped) = name.strip_suffix(suffix) {
                name = stripped.to_string();
                break;
            }
        }
        let destination = cache.join(&name);
        let marker = destination.join(".extracted");
        if !marker.is_file() {
            files::directory(&destination).map_err(io_error)?;
            shell::inherit(
                &[
                    "cmake".to_string(),
                    "-E".to_string(),
                    "tar".to_string(),
                    "xf".to_string(),
                    archive.to_string_lossy().into_owned(),
                ],
                Some(&destination),
                &environment(),
                None,
            )?;
            files::write(&marker, b"").map_err(io_error)?;
        }
        let mut roots: Vec<PathBuf> = std::fs::read_dir(&destination)
            .map_err(io_error)?
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .collect();
        roots.sort();
        match roots.as_slice() {
            [root] => Ok(root.clone()),
            _ => Err(ToolError::message(format!(
                "Unexpected upstream archive layout: {}",
                archive.display()
            ))),
        }
    }
}

fn io_error(error: io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

/// Swift's `Shell.inherit` defaults to the process environment.
fn environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}
