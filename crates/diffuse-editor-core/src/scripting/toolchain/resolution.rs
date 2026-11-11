//! Translation of Editor/Sources/EditorCore/Scripting/Toolchain/Resolution.swift
//! (MIGRATION.md §4 d1: the editor's script toolchain is rustup + cargo, so the
//! Swift compiler probes become rustc probes).
//!
//! The Swift type names are kept (`SwiftToolchain*`) because the persisted
//! preferences and the script pipeline refer to them; behaviour is Rust's.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cove_system::process::{ProcessCommand, ProcessLimits, ProcessSession};

use super::preferences::SwiftToolchainPreferences;
use crate::scripting::rust_analyzer::server::executable_locator::RustAnalyzerExecutableLocator;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwiftToolchain {
    /// `rustc` in the toolchain's `bin/`.
    pub compiler_url: PathBuf,
    /// `rust-analyzer` in the same `bin/`.
    pub language_server_url: PathBuf,
    pub root_url: PathBuf,
    pub version: String,
    /// The platform SDK. Rust toolchains carry their own sysroot, so this is
    /// `None` unless an explicit `SDKROOT` is configured.
    pub sdk_url: Option<PathBuf>,
    pub environment: BTreeMap<String, String>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum SwiftToolchainError {
    #[error("{0}")]
    Unavailable(String),
    #[error("{0}")]
    InvalidInstallation(String),
    #[error("Confirm the official Rust toolchain installation before installing.")]
    ConfirmationRequired,
    #[error(
        "Automatic installation is not available for this platform. Install a Rust toolchain with rustup (https://rustup.rs) and select its path."
    )]
    UnsupportedPlatform,
    #[error("A Rust toolchain installation is already in progress.")]
    InstallationInProgress,
}

pub struct SwiftToolchainResolver;

impl SwiftToolchainResolver {
    /// `resolve(compilerOverride:environment:preferences:)`; the environment and
    /// preferences default to the process values.
    pub fn resolve(
        compiler_override: Option<&str>,
        environment: &BTreeMap<String, String>,
        preferences: &SwiftToolchainPreferences,
    ) -> Result<SwiftToolchain, SwiftToolchainError> {
        let explicit = [
            compiler_override.map(str::to_string),
            environment.get("COVE_RUSTC_PATH").cloned(),
            environment.get("COVE_RUST_TOOLCHAIN_PATH").cloned(),
            preferences.selected_path.clone(),
        ]
        .into_iter()
        .flatten()
        .find(|value| !value.trim().is_empty());

        if let Some(explicit) = explicit {
            return Self::inspect(&Self::compiler_url(&explicit, environment)?, environment);
        }
        if let Some(lsp) = environment.get(RustAnalyzerExecutableLocator::OVERRIDE_ENVIRONMENT_KEY)
            && !lsp.is_empty()
            && let Ok(executable) =
                diffuse_script::dynamic_script::script_compiler::ScriptCompiler::resolve_executable_url(
                    lsp, environment,
                )
        {
            let bin = executable.parent().unwrap_or(&executable);
            return Self::inspect(&bin.join(compiler_name()), environment);
        }

        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Ok(found) =
            diffuse_script::dynamic_script::script_compiler::ScriptCompiler::resolve_executable_url(
                "rustc",
                environment,
            )
        {
            candidates.push(found);
        }
        for root in installed_roots(environment) {
            let Ok(children) = std::fs::read_dir(&root) else {
                continue;
            };
            for child in children.flatten() {
                candidates.push(child.path());
            }
        }

        let mut failures: Vec<String> = Vec::new();
        for candidate in candidates {
            match Self::compiler_url(&candidate.to_string_lossy(), environment)
                .and_then(|compiler| Self::inspect(&compiler, environment))
            {
                Ok(toolchain) => return Ok(toolchain),
                Err(error) => failures.push(error.to_string()),
            }
        }
        Err(SwiftToolchainError::Unavailable(if failures.is_empty() {
            "No Rust toolchain was found. Select a toolchain path or install one with rustup."
                .to_string()
        } else {
            failures.join("\n")
        }))
    }

    /// `resolve(environment:)` with Swift's defaults.
    pub fn resolve_default() -> Result<SwiftToolchain, SwiftToolchainError> {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::resolve(
            None,
            &environment,
            &SwiftToolchainPreferences::load_with_default(),
        )
    }

    pub fn installed(environment: &BTreeMap<String, String>) -> Vec<SwiftToolchain> {
        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Ok(current) = Self::resolve(
            None,
            environment,
            &SwiftToolchainPreferences::load_with_default(),
        ) {
            candidates.push(current.compiler_url);
        }
        for root in installed_roots(environment) {
            let Ok(children) = std::fs::read_dir(&root) else {
                continue;
            };
            for child in children.flatten() {
                candidates.push(child.path());
            }
        }
        let mut seen: std::collections::BTreeSet<PathBuf> = std::collections::BTreeSet::new();
        let mut toolchains = Vec::new();
        for candidate in candidates {
            let Ok(compiler) = Self::compiler_url(&candidate.to_string_lossy(), environment) else {
                continue;
            };
            let Ok(toolchain) = Self::inspect(&compiler, environment) else {
                continue;
            };
            if seen.insert(toolchain.root_url.clone()) {
                toolchains.push(toolchain);
            }
        }
        toolchains
    }

    /// `compilerURL(at:environment:)` — a directory is probed for the toolchain
    /// layout, a file is resolved through PATH.
    pub fn compiler_url(
        path: &str,
        environment: &BTreeMap<String, String>,
    ) -> Result<PathBuf, SwiftToolchainError> {
        let path_ref = Path::new(path);
        if path_ref.is_dir() {
            let root = path_ref;
            for relative in [
                format!("bin/{}", compiler_name()),
                compiler_name().to_string(),
                format!("usr/bin/{}", compiler_name()),
            ] {
                let candidate = root.join(relative);
                if is_executable(&candidate) {
                    return Ok(candidate);
                }
            }
            return Err(SwiftToolchainError::Unavailable(format!(
                "The selected directory does not contain rustc: {path}"
            )));
        }
        diffuse_script::dynamic_script::script_compiler::ScriptCompiler::resolve_executable_url(
            path,
            environment,
        )
        .map_err(|error| SwiftToolchainError::Unavailable(error.to_string()))
    }

    pub fn inspect(
        compiler_url: &Path,
        environment: &BTreeMap<String, String>,
    ) -> Result<SwiftToolchain, SwiftToolchainError> {
        let mut launch_environment = environment.clone();
        let sdk = environment
            .get("SDKROOT")
            .filter(|value| !value.is_empty())
            .map(|value| {
                let url = PathBuf::from(value);
                if !url.join("SDKSettings.json").is_file()
                    && !url.join("SDKSettings.plist").is_file()
                {
                    return Err(SwiftToolchainError::Unavailable(format!(
                        "The configured SDK is invalid: {value}"
                    )));
                }
                Ok(url)
            })
            .transpose()?;

        let data = Self::probe(compiler_url, &["--print", "sysroot"], &launch_environment)?;
        let sysroot_text = String::from_utf8_lossy(&data).trim().to_string();
        if sysroot_text.is_empty() {
            return Err(SwiftToolchainError::Unavailable(format!(
                "rustc could not report its sysroot: {}",
                compiler_url.display()
            )));
        }
        let sysroot =
            std::fs::canonicalize(&sysroot_text).unwrap_or_else(|_| PathBuf::from(&sysroot_text));
        if !sysroot.is_dir() {
            return Err(SwiftToolchainError::Unavailable(format!(
                "The Rust standard library directory is missing: {sysroot_text}"
            )));
        }
        let version = Self::probe(compiler_url, &["--version"], &launch_environment)?;
        let version = String::from_utf8_lossy(&version).trim().to_string();

        let binary_directory = compiler_url
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| sysroot.join("bin"));
        let fixed_compiler = binary_directory.join(compiler_name());
        let fixed_lsp = binary_directory.join(language_server_name());
        let fixed_cargo = binary_directory.join(cargo_name());
        if !is_executable(&fixed_compiler)
            || !is_executable(&fixed_lsp)
            || !is_executable(&fixed_cargo)
        {
            return Err(SwiftToolchainError::Unavailable(format!(
                "The Rust toolchain must include matching rustc, cargo and rust-analyzer binaries: {}",
                binary_directory.display()
            )));
        }
        let root = binary_directory
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| binary_directory.clone());
        let separator = if cfg!(windows) { ";" } else { ":" };
        let path_value = format!(
            "{}{separator}{}",
            binary_directory.display(),
            environment.get("PATH").cloned().unwrap_or_default()
        );
        launch_environment.insert("PATH".to_string(), path_value);
        launch_environment.insert(
            "RUSTUP_TOOLCHAIN".to_string(),
            root.to_string_lossy().into_owned(),
        );
        launch_environment.insert(
            "CARGO".to_string(),
            fixed_cargo.to_string_lossy().into_owned(),
        );
        launch_environment.insert(
            "RUSTC".to_string(),
            fixed_compiler.to_string_lossy().into_owned(),
        );
        if let Some(sdk) = sdk.as_ref() {
            launch_environment.insert("SDKROOT".to_string(), sdk.to_string_lossy().into_owned());
        }

        Ok(SwiftToolchain {
            compiler_url: fixed_compiler,
            language_server_url: fixed_lsp,
            root_url: root,
            version,
            sdk_url: sdk,
            environment: launch_environment,
        })
    }

    pub fn probe(
        executable: &Path,
        arguments: &[&str],
        environment: &BTreeMap<String, String>,
    ) -> Result<Vec<u8>, SwiftToolchainError> {
        let mut command = ProcessCommand::new(executable).map_err(|error| {
            SwiftToolchainError::Unavailable(format!(
                "Could not start {}: {error}",
                executable.display()
            ))
        })?;
        command.directory = std::env::temp_dir();
        command.arguments = arguments.iter().map(|argument| argument.into()).collect();
        command.environment = environment
            .iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect();
        let limits = ProcessLimits {
            timeout: std::time::Duration::from_secs(10),
            output_bytes: 1_048_576,
            ..ProcessLimits::default()
        };
        let output = ProcessSession::spawn(&command, limits)
            .and_then(|session| session.collect())
            .map_err(|error| {
                SwiftToolchainError::Unavailable(format!(
                    "Could not run {}: {error}",
                    executable.display()
                ))
            })?;
        if output.code != 0 {
            let mut message = output.stderr;
            message.extend_from_slice(&output.stdout);
            return Err(SwiftToolchainError::Unavailable(
                String::from_utf8_lossy(&message).into_owned(),
            ));
        }
        Ok(output.stdout)
    }
}

/// Roots that hold installed toolchains: the editor's own directory plus rustup's.
fn installed_roots(environment: &BTreeMap<String, String>) -> Vec<PathBuf> {
    let mut roots = vec![SwiftToolchainPreferences::directory().join("Installed")];
    if let Some(rustup_home) = environment.get("RUSTUP_HOME") {
        roots.push(PathBuf::from(rustup_home).join("toolchains"));
    } else if let Some(home) = home_directory() {
        roots.push(home.join(".rustup").join("toolchains"));
    }
    roots.retain(|root| root.is_dir());
    roots
}

fn home_directory() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("USERPROFILE").map(PathBuf::from)
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}

fn is_executable(path: &Path) -> bool {
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

fn compiler_name() -> &'static str {
    if cfg!(windows) { "rustc.exe" } else { "rustc" }
}

fn language_server_name() -> &'static str {
    if cfg!(windows) {
        "rust-analyzer.exe"
    } else {
        "rust-analyzer"
    }
}

fn cargo_name() -> &'static str {
    if cfg!(windows) { "cargo.exe" } else { "cargo" }
}
