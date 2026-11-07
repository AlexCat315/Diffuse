//! Locating the FFmpeg command line tools.
//!
//! `cove-media` builds FFmpeg 9.x into `OUT_DIR` with `--disable-programs`, so
//! no CLI is part of that artifact. Diffuse resolves the external tools in this
//! order: an explicit override, tools shipped beside the executable, then the
//! system `PATH` (Homebrew's FFmpeg 9.x on macOS). The pinned 8.1.3
//! `FFmpeg.artifactbundle/<variant>/bin` candidate was removed with the
//! artifact bundle in batch 85.

use std::path::{Path, PathBuf};

use crate::decoding::values::MediaError;

/// `public enum FFmpegTools`.
pub struct FFmpegTools;

#[cfg(windows)]
const FFMPEG_NAME: &str = "ffmpeg.exe";
#[cfg(not(windows))]
const FFMPEG_NAME: &str = "ffmpeg";

#[cfg(windows)]
const FFPROBE_NAME: &str = "ffprobe.exe";
#[cfg(not(windows))]
const FFPROBE_NAME: &str = "ffprobe";

impl FFmpegTools {
    /// Environment override consulted before the shipped locations.
    pub const EXECUTABLE_OVERRIDE: &'static str = "COVE_FFMPEG_EXECUTABLE";
    /// Separate override for the probe used by `MediaAsset::inspect`.
    pub const PROBE_OVERRIDE: &'static str = "COVE_FFPROBE_EXECUTABLE";

    /// `public static func executable() throws -> URL`.
    pub fn executable() -> Result<PathBuf, MediaError> {
        Self::locate(FFMPEG_NAME, Self::EXECUTABLE_OVERRIDE)
    }

    /// The probe ships alongside `ffmpeg` in every FFmpeg distribution.
    pub fn ffprobe() -> Result<PathBuf, MediaError> {
        Self::locate(FFPROBE_NAME, Self::PROBE_OVERRIDE)
    }

    fn locate(name: &str, override_variable: &str) -> Result<PathBuf, MediaError> {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Some(override_path) = std::env::var_os(override_variable) {
            candidates.push(PathBuf::from(override_path));
        }
        let directory = executable_directory();
        candidates.push(directory.join("Tools").join(name));
        if let Some(parent) = directory.parent() {
            candidates.push(parent.join("Helpers").join(name));
        } else {
            // `deletingLastPathComponent()` of a root directory yields the root.
            candidates.push(directory.join("Helpers").join(name));
        }
        if let Some(paths) = std::env::var_os("PATH") {
            for entry in std::env::split_paths(&paths) {
                candidates.push(entry.join(name));
            }
        }
        candidates
            .into_iter()
            .find(|candidate| is_executable_file(candidate))
            .ok_or_else(|| {
                MediaError::Export(format!(
                    "{name} is missing. Install FFmpeg 9.x or set {override_variable}."
                ))
            })
    }
}

/// `Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL`.
///
/// Rust has no bundle: the process executable's parent directory stands in.
fn executable_directory() -> PathBuf {
    match std::env::current_exe() {
        Ok(path) => path.parent().map(PathBuf::from).unwrap_or(path),
        Err(_) => std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    }
}

/// `FileManager.default.isExecutableFile(atPath:)`.
fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}
