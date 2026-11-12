//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/SourceKitLSPExecutableLocatorTests.swift`
//! (toolchain lookup cases; capability negotiation has no rust-analyzer analog).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use diffuse_lsp::lsp::error::LspClientError;

use crate::scripting::rust_analyzer::server::executable_locator::RustAnalyzerExecutableLocator;

fn temporary_directory() -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "cove-lsp-stub-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&directory).expect("stub directory");
    directory
}

fn make_stub_executable(directory: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        // Windows checks the PE header, not a POSIX mode.
        let system_root = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        let source = PathBuf::from(system_root).join("System32/cmd.exe");
        let destination = directory.join("rust-analyzer.exe");
        std::fs::copy(source, &destination).expect("copy cmd.exe stub");
        destination
    }
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::PermissionsExt;
        let destination = directory.join("rust-analyzer");
        std::fs::write(&destination, "").expect("write stub");
        std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o755))
            .expect("chmod stub");
        destination
    }
}

fn environment(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
        .collect()
}

/// Resolves rust-analyzer from an explicit executable override.
#[test]
fn resolves_explicit_path() {
    let directory = temporary_directory();
    let executable = make_stub_executable(&directory);
    let url = RustAnalyzerExecutableLocator::resolve_executable_url(&environment(&[(
        RustAnalyzerExecutableLocator::OVERRIDE_ENVIRONMENT_KEY,
        executable.to_str().expect("stub path"),
    )]))
    .expect("override");
    assert_eq!(url, executable);
    std::fs::remove_dir_all(directory).ok();
}

/// Reports the override path when it is not executable.
#[test]
fn rejects_non_executable_override() {
    let error = RustAnalyzerExecutableLocator::resolve_executable_url(&environment(&[(
        RustAnalyzerExecutableLocator::OVERRIDE_ENVIRONMENT_KEY,
        "/nonexistent/rust-analyzer",
    )]))
    .expect_err("missing override");
    assert_eq!(
        error,
        LspClientError::ExecutableNotFound("/nonexistent/rust-analyzer".to_string())
    );
}

/// Falls through to PATH.
#[test]
fn finds_from_path() {
    let directory = temporary_directory();
    let executable = make_stub_executable(&directory);
    let path = directory.to_str().expect("directory path");
    let url = RustAnalyzerExecutableLocator::resolve_executable_url(&environment(&[
        ("PATH", path),
        #[cfg(windows)]
        ("PATHEXT", ".EXE;.CMD"),
    ]))
    .expect("path lookup");
    #[cfg(windows)]
    assert_eq!(
        url.to_string_lossy().to_lowercase(),
        executable.to_string_lossy().to_lowercase()
    );
    #[cfg(not(windows))]
    assert_eq!(url, executable);
    std::fs::remove_dir_all(directory).ok();
}

/// Fails with a descriptive error when nothing can be found.
#[test]
fn fails_when_absent() {
    let error = RustAnalyzerExecutableLocator::resolve_executable_url(&environment(&[(
        "PATH",
        "/nonexistent/bin",
    )]))
    .expect_err("absent");
    assert_eq!(
        error,
        LspClientError::ExecutableNotFound("rust-analyzer".to_string())
    );
}
