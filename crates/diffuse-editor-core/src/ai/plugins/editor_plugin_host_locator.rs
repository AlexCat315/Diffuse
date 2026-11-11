//! `Editor/Sources/EditorCore/AI/Plugins/EditorPluginHostLocator.swift`.
//!
//! Plugin packages, AI output, project settings and environment variables are
//! deliberately not consulted. Tests and embedding applications may inject a
//! path through the Rust equivalents of `injectedURL` / `Bundle`, and that call
//! site is part of the trusted host boundary rather than plugin-controlled data.

use std::fs;
use std::path::{Path, PathBuf};

pub struct EditorPluginHostLocator;

impl EditorPluginHostLocator {
    pub fn executable_name() -> &'static str {
        #[cfg(windows)]
        {
            "DiffusePluginHost.exe"
        }
        #[cfg(not(windows))]
        {
            "DiffusePluginHost"
        }
    }

    /// Swift's `resolve(injectedURL:bundle:)` with `bundle = .main`.
    pub fn resolve(injected_url: Option<&Path>) -> Option<PathBuf> {
        if let Some(injected_url) = injected_url {
            return validated_executable(injected_url);
        }
        let executable_url = std::env::current_exe().ok();
        let bundle_url = main_bundle_url(executable_url.as_deref());
        Self::resolve_in(None, &bundle_url, executable_url.as_deref())
    }

    /// Swift's third parameter, exposed so tests can model a bundle layout.
    ///
    /// `bundle_url` is the Foundation `Bundle.bundleURL` equivalent: `.app` on
    /// macOS, the executable's directory elsewhere.
    pub fn resolve_in(
        injected_url: Option<&Path>,
        bundle_url: &Path,
        executable_url: Option<&Path>,
    ) -> Option<PathBuf> {
        if let Some(injected_url) = injected_url {
            return validated_executable(injected_url);
        }
        let name = Self::executable_name();
        let mut candidates: Vec<PathBuf> = Vec::new();
        candidates.push(bundle_url.join("Contents").join("Helpers").join(name));
        if let Some(directory) = executable_url.and_then(Path::parent) {
            candidates.push(directory.join("Tools").join(name));
            candidates.push(directory.join(name));
        }
        #[cfg(debug_assertions)]
        {
            // Swift searched SwiftPM's `.build/out/Products/Debug` and
            // `.build/debug`; with Cargo the equivalent product directory is
            // `<workspace>/target/debug`.
            let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
            if let Some(repository_root) = manifest_dir.ancestors().nth(2) {
                candidates.push(repository_root.join("target").join("debug").join(name));
            }
        }
        candidates
            .into_iter()
            .find_map(|candidate| validated_executable(&candidate))
    }
}

/// Foundation `Bundle.main.bundleURL` for a running executable.
fn main_bundle_url(executable_url: Option<&Path>) -> PathBuf {
    let Some(executable_url) = executable_url else {
        return PathBuf::new();
    };
    #[cfg(target_os = "macos")]
    {
        // `<App>.app/Contents/MacOS/<exe>` → `<App>.app`; unbundled executables
        // fall through to their own directory, matching Foundation.
        if let Some(contents) = executable_url.parent().and_then(Path::parent) {
            if contents.file_name().and_then(|name| name.to_str()) == Some("Contents") {
                if let Some(bundle) = contents.parent() {
                    return bundle.to_path_buf();
                }
            }
        }
    }
    executable_url
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

fn validated_executable(candidate: &Path) -> Option<PathBuf> {
    let absolute = std::path::absolute(candidate).ok()?;
    let source = fs::symlink_metadata(&absolute).ok()?;
    if source.file_type().is_symlink() {
        return None;
    }
    let resolved = strip_verbatim_prefix(fs::canonicalize(&absolute).ok()?);
    let metadata = fs::symlink_metadata(&resolved).ok()?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return None;
    }
    if !is_executable_file(&resolved) {
        return None;
    }
    Some(resolved)
}

fn is_executable_file(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        return fs::metadata(path)
            .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
    }
    #[cfg(windows)]
    {
        if !fs::metadata(path)
            .map(|metadata| metadata.is_file())
            .unwrap_or(false)
        {
            return false;
        }
        return path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| {
                matches!(
                    extension.to_ascii_lowercase().as_str(),
                    "exe" | "com" | "bat" | "cmd"
                )
            })
            .unwrap_or(false);
    }
    #[cfg(not(any(unix, windows)))]
    {
        fs::metadata(path)
            .map(|metadata| metadata.is_file())
            .unwrap_or(false)
    }
}

#[cfg(windows)]
fn strip_verbatim_prefix(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    if let Some(rest) = text.strip_prefix(r"\\?\") {
        return PathBuf::from(rest);
    }
    path
}

#[cfg(not(windows))]
fn strip_verbatim_prefix(path: PathBuf) -> PathBuf {
    path
}
