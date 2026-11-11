//! Translation of
//! Editor/Sources/EditorCore/Scripting/SourceKitLSP/SourceKit/SourceKitLSPExecutableLocator.swift.
//!
//! MIGRATION.md §4 (d1) rewrites this file for the Rust script pipeline: user
//! scripts are cargo-built cdylibs served by `rust-analyzer`, so the locator
//! looks for `rust-analyzer` (and `rustup which rust-analyzer`) instead of
//! `sourcekit-lsp`/`xcrun`.
//!
//! /// Locates a usable `rust-analyzer` executable on the host.
//!
//! Resolution order mirrors what an editor extension does: an explicit operator
//! override first, then `PATH`, then whatever toolchain `rustup` reports.

use std::collections::BTreeMap;
use std::path::PathBuf;

use diffuse_lsp::lsp::error::LspClientError;
use diffuse_script::dynamic_script::script_compiler::ScriptCompiler;

pub struct RustAnalyzerExecutableLocator;

impl RustAnalyzerExecutableLocator {
    /// Swift's `SourceKitLSPExecutableLocator.overrideEnvironmentKey`.
    pub const OVERRIDE_ENVIRONMENT_KEY: &'static str = "COVE_RUST_ANALYZER_PATH";

    pub fn resolve_executable_url(
        environment: &BTreeMap<String, String>,
    ) -> Result<PathBuf, LspClientError> {
        if let Some(override_path) = environment.get(Self::OVERRIDE_ENVIRONMENT_KEY)
            && !override_path.is_empty()
        {
            return ScriptCompiler::resolve_executable_url(override_path, environment)
                .map_err(|_| LspClientError::ExecutableNotFound(override_path.clone()));
        }

        if let Ok(path) = ScriptCompiler::resolve_executable_url("rust-analyzer", environment) {
            return Ok(path);
        }

        if let Ok(rustup) = ScriptCompiler::resolve_executable_url("rustup", environment)
            && let Some(found) = resolve_via_rustup(&rustup, environment)
        {
            return Ok(found);
        }

        Err(LspClientError::ExecutableNotFound(
            "rust-analyzer".to_string(),
        ))
    }

    /// `resolveExecutableURL(environment:)` with the process environment.
    pub fn resolve_executable_url_default() -> Result<PathBuf, LspClientError> {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::resolve_executable_url(&environment)
    }
}

/// Swift asked `xcrun --find`; the Rust toolchain answers through `rustup`.
fn resolve_via_rustup(
    rustup: &std::path::Path,
    environment: &BTreeMap<String, String>,
) -> Option<PathBuf> {
    let mut command = std::process::Command::new(rustup);
    command.args(["which", "rust-analyzer"]);
    for (key, value) in environment {
        command.env(key, value);
    }
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        return None;
    }
    Some(PathBuf::from(path))
}
