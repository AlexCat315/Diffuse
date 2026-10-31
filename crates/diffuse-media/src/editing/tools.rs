//! Locating the pinned FFmpeg executable.
//!
//! Installed workstations ship a pinned tool beside their executable; source
//! builds use the same tool staged under `vendor/`. The Swift version resolved
//! its package root from `#filePath`, which Rust replaces with
//! `CARGO_MANIFEST_DIR` at compile time and the artifact root at run time
//! (`DIFFUSE_NATIVE_ROOT`, default `vendor/`, MIGRATION.md §2.3).
//!
//! Every `#if os` / `#if arch` branch of the Swift source becomes a `#[cfg]` here
//! (MIGRATION.md §2.3, "platform coverage").

use std::path::PathBuf;

use crate::decoding::values::MediaError;

/// `public enum FFmpegTools`.
pub struct FFmpegTools;

/// `let name = "ffmpeg.exe" if Windows else "ffmpeg"`.
#[cfg(windows)]
const EXECUTABLE_NAME: &str = "ffmpeg.exe";
#[cfg(not(windows))]
const EXECUTABLE_NAME: &str = "ffmpeg";

/// The `vendor/FFmpeg.artifactbundle/<variant>/bin` component.
const ARTIFACT_VARIANT: &str = variant_directory();

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const fn variant_directory() -> &'static str {
    "macos-arm64"
}

#[cfg(all(target_os = "macos", not(target_arch = "aarch64")))]
const fn variant_directory() -> &'static str {
    "macos-x86_64"
}

#[cfg(all(windows, target_arch = "aarch64"))]
const fn variant_directory() -> &'static str {
    "windows-arm64"
}

#[cfg(all(windows, not(target_arch = "aarch64")))]
const fn variant_directory() -> &'static str {
    "windows-x86_64"
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
const fn variant_directory() -> &'static str {
    "linux-aarch64"
}

#[cfg(all(target_os = "linux", not(target_arch = "aarch64")))]
const fn variant_directory() -> &'static str {
    "linux-x86_64"
}

#[cfg(all(target_os = "android", target_arch = "aarch64"))]
const fn variant_directory() -> &'static str {
    "android-arm64"
}

#[cfg(all(target_os = "android", not(target_arch = "aarch64")))]
const fn variant_directory() -> &'static str {
    "android-x86_64"
}

#[cfg(all(target_os = "ios", target_arch = "aarch64"))]
const fn variant_directory() -> &'static str {
    "ios-arm64"
}

impl FFmpegTools {
    /// Environment override consulted before the shipped locations.
    pub const EXECUTABLE_OVERRIDE: &'static str = "COVE_FFMPEG_EXECUTABLE";

    /// `public static func executable() throws -> URL`.
    ///
    /// Candidates, in Swift's order:
    /// 1. `COVE_FFMPEG_EXECUTABLE`, when set (inserted first);
    /// 2. `<executable dir>/Tools/ffmpeg`;
    /// 3. `<executable dir>/../Helpers/ffmpeg`;
    /// 4. `<package root>/vendor/FFmpeg.artifactbundle/<variant>/bin/ffmpeg`.
    ///
    /// `<executable dir>` is the directory of the running binary, as
    /// `Bundle.main.executableURL` reports it.
    pub fn executable() -> Result<PathBuf, MediaError> {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Some(override_path) = std::env::var_os(Self::EXECUTABLE_OVERRIDE) {
            candidates.push(PathBuf::from(override_path));
        }
        let directory = executable_directory();
        candidates.push(directory.join("Tools").join(EXECUTABLE_NAME));
        if let Some(parent) = directory.parent() {
            candidates.push(parent.join("Helpers").join(EXECUTABLE_NAME));
        } else {
            // `deletingLastPathComponent()` of a root directory yields the root.
            candidates.push(directory.join("Helpers").join(EXECUTABLE_NAME));
        }
        candidates.push(
            package_root()
                .join("vendor")
                .join("FFmpeg.artifactbundle")
                .join(ARTIFACT_VARIANT)
                .join("bin")
                .join(EXECUTABLE_NAME),
        );
        match candidates
            .into_iter()
            .find(|candidate| is_executable_file(candidate.as_path()))
        {
            Some(found) => Ok(found),
            None => Err(MediaError::Export(
                "Pinned FFmpeg tool is missing. Run `cargo xtask native-bootstrap` or configure COVE_FFMPEG_EXECUTABLE."
                    .to_string(),
            )),
        }
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

/// Swift derived the package root from `#filePath` (four `deletingLastPathComponent`
/// calls from `Sources/MediaRuntime/Editing/Tools.swift`). The Rust crate lives at
/// `crates/diffuse-media/src/editing/tools.rs`, so `CARGO_MANIFEST_DIR/../..` is the
/// workspace root that holds `vendor/`.
fn package_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")))
}

/// `FileManager.default.isExecutableFile(atPath:)`.
fn is_executable_file(path: &std::path::Path) -> bool {
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
