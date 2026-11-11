//! Translation of
//! Editor/Sources/EditorCore/Scripting/Toolchain/AnalysisEnvironment.swift
//! (MIGRATION.md §4 d1: the analysis SDK is rustc's sysroot plus the engine
//! crates, so the Swift-module preflight becomes a sysroot + path preflight).
//!
//! Swift compiled a Swift file against `ScriptRuntime`/`SceneRuntime` modules to
//! prove the analysis environment works. Rust's equivalent is: the toolchain's
//! standard library must be present for the host target, every configured
//! module/include path must exist, and a probe crate must typecheck against the
//! engine's script API.

use std::path::{Path, PathBuf};

use cove_system::process::{ProcessCommand, ProcessLimits, ProcessSession};

use super::resolution::{SwiftToolchain, SwiftToolchainError};

impl SwiftToolchain {
    pub fn validate_analysis(
        &self,
        engine_module_paths: &[String],
        clang_module_map_paths: &[String],
        clang_include_paths: &[String],
    ) -> Result<(), SwiftToolchainError> {
        let sysroot = PathBuf::from(Self::probe_stdout(
            &self.compiler_url,
            &["--print", "sysroot"],
            &self.environment,
        )?);
        let target = Self::probe_stdout(
            &self.compiler_url,
            &["--print", "target-triple"],
            &self.environment,
        )?;
        let target_lib = sysroot.join("lib").join("rustlib").join(target.trim());
        if !target_lib.is_dir() {
            return Err(SwiftToolchainError::Unavailable(format!(
                "The Rust toolchain is missing its standard library for {}. Install it with rustup (component rust-std).",
                target.trim()
            )));
        }
        for path in engine_module_paths {
            if !Path::new(path).is_dir() {
                return Err(SwiftToolchainError::Unavailable(format!(
                    "A script crate path is missing: {path}"
                )));
            }
        }
        for path in clang_module_map_paths {
            if !Path::new(path).is_file() {
                return Err(SwiftToolchainError::Unavailable(format!(
                    "A Clang module map is missing: {path}"
                )));
            }
        }
        for path in clang_include_paths {
            if !Path::new(path).is_dir() {
                return Err(SwiftToolchainError::Unavailable(format!(
                    "A Clang include directory is missing: {path}"
                )));
            }
        }

        let directory = std::env::temp_dir().join(format!(
            "diffuse-rust-preflight-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        std::fs::create_dir_all(&directory).map_err(io_unavailable)?;
        let result = self.run_preflight(&directory);
        let _ = std::fs::remove_dir_all(&directory);
        result
    }

    /// Typechecks a probe crate the same way `cargo check` will see user scripts.
    fn run_preflight(&self, directory: &Path) -> Result<(), SwiftToolchainError> {
        let source = directory.join("probe.rs");
        std::fs::write(
            &source,
            "pub fn cove_script_library_probe() -> &'static str { \"ready\" }\n",
        )
        .map_err(io_unavailable)?;

        let mut arguments: Vec<std::ffi::OsString> = vec![
            "--edition".into(),
            "2024".into(),
            "--crate-type".into(),
            "lib".into(),
            "--emit".into(),
            "metadata".into(),
            "-o".into(),
            directory.join("probe.rmeta").into_os_string(),
            "-C".into(),
            "metadata=diffuse_probe".into(),
        ];
        arguments.push(source.into_os_string());

        let mut command = ProcessCommand::new(&self.compiler_url).map_err(io_unavailable)?;
        command.directory = directory.to_path_buf();
        command.arguments = arguments;
        command.environment = self
            .environment
            .iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect();
        let limits = ProcessLimits {
            timeout: std::time::Duration::from_secs(120),
            output_bytes: 1_048_576,
            ..ProcessLimits::default()
        };
        let output = ProcessSession::spawn(&command, limits)
            .and_then(|session| session.collect())
            .map_err(io_unavailable)?;
        if output.code != 0 {
            let mut message = output.stderr;
            message.extend_from_slice(&output.stdout);
            return Err(SwiftToolchainError::Unavailable(format!(
                "Rust analysis environment validation failed. The selected compiler and engine script API must match.\n{}",
                String::from_utf8_lossy(&message)
            )));
        }
        Ok(())
    }

    fn probe_stdout(
        compiler_url: &Path,
        arguments: &[&str],
        environment: &std::collections::BTreeMap<String, String>,
    ) -> Result<String, SwiftToolchainError> {
        let output =
            super::resolution::SwiftToolchainResolver::probe(compiler_url, arguments, environment)?;
        Ok(String::from_utf8_lossy(&output).trim().to_string())
    }
}

fn io_unavailable(error: std::io::Error) -> SwiftToolchainError {
    SwiftToolchainError::Unavailable(error.to_string())
}
