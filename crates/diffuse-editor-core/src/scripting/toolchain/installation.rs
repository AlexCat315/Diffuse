//! Translation of Editor/Sources/EditorCore/Scripting/Toolchain/Installation.swift
//! (MIGRATION.md §4 d1: installation is delegated to rustup instead of
//! downloading and verifying an Apple-signed Swift package).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use cove_system::process::{ProcessCommand, ProcessLimits, ProcessSession};

use super::preferences::SwiftToolchainPreferences;
use super::resolution::{SwiftToolchain, SwiftToolchainError, SwiftToolchainResolver};

/// One `rustup` toolchain name (`stable`, `beta`, `nightly`, or a pinned version).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SwiftToolchainRelease {
    pub version: String,
}

impl SwiftToolchainRelease {
    pub fn new(version: impl Into<String>) -> Self {
        SwiftToolchainRelease {
            version: version.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SwiftToolchainInstallProgress {
    Downloading {
        received_bytes: i64,
        total_bytes: Option<i64>,
    },
    Verifying,
    Installing,
    Completed(PathBuf),
    Cancelled,
    Failed(String),
}

pub struct SwiftToolchainInstallation {
    directory: PathBuf,
    is_installing: Mutex<bool>,
}

impl Default for SwiftToolchainInstallation {
    fn default() -> Self {
        Self::new(SwiftToolchainPreferences::directory())
    }
}

impl SwiftToolchainInstallation {
    /// Swift listed fixed download URLs; rustup resolves releases itself, so the
    /// editor only offers the three channels.
    pub fn releases() -> Vec<SwiftToolchainRelease> {
        ["stable", "beta", "nightly"]
            .into_iter()
            .map(SwiftToolchainRelease::new)
            .collect()
    }

    pub fn new(directory: PathBuf) -> Self {
        SwiftToolchainInstallation {
            directory,
            is_installing: Mutex::new(false),
        }
    }

    pub fn install(
        &self,
        version: &str,
        confirmed: bool,
        on_progress: impl Fn(SwiftToolchainInstallProgress) + Send + Sync,
    ) -> Result<SwiftToolchain, SwiftToolchainError> {
        if !confirmed {
            return Err(SwiftToolchainError::ConfirmationRequired);
        }
        if !Self::releases()
            .iter()
            .any(|release| release.version == version)
        {
            return Err(SwiftToolchainError::UnsupportedPlatform);
        }
        {
            let mut installing = self
                .is_installing
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if *installing {
                return Err(SwiftToolchainError::InstallationInProgress);
            }
            *installing = true;
            std::fs::create_dir_all(&self.directory).map_err(|error| {
                SwiftToolchainError::InvalidInstallation(format!(
                    "Could not create the toolchain directory: {error}"
                ))
            })?;
        }
        let guard = InstallGuard {
            is_installing: &self.is_installing,
        };

        let environment: BTreeMap<String, String> = std::env::vars().collect();
        let result = self.install_rustup(version, &environment, &on_progress);
        drop(guard);
        match &result {
            Ok(toolchain) => on_progress(SwiftToolchainInstallProgress::Completed(
                toolchain.root_url.clone(),
            )),
            Err(error) => on_progress(SwiftToolchainInstallProgress::Failed(error.to_string())),
        }
        result
    }

    fn install_rustup(
        &self,
        version: &str,
        environment: &BTreeMap<String, String>,
        on_progress: &(impl Fn(SwiftToolchainInstallProgress) + Send + Sync),
    ) -> Result<SwiftToolchain, SwiftToolchainError> {
        let rustup =
            diffuse_script::dynamic_script::script_compiler::ScriptCompiler::resolve_executable_url(
                "rustup", environment,
            )
            .map_err(|error| SwiftToolchainError::Unavailable(error.to_string()))?;

        on_progress(SwiftToolchainInstallProgress::Downloading {
            received_bytes: 0,
            total_bytes: None,
        });
        Self::run_rustup(
            &rustup,
            &["toolchain", "install", version, "--no-self-update"],
            environment,
        )?;

        on_progress(SwiftToolchainInstallProgress::Verifying);
        let compiler_path = Self::run_rustup(
            &rustup,
            &["which", "--toolchain", version, "rustc"],
            environment,
        )?;
        let compiler_path = compiler_path.trim();
        if compiler_path.is_empty() {
            return Err(SwiftToolchainError::InvalidInstallation(format!(
                "rustup did not report a rustc path for toolchain {version}."
            )));
        }

        on_progress(SwiftToolchainInstallProgress::Installing);
        Self::run_rustup(
            &rustup,
            &["component", "add", "rust-analyzer", "--toolchain", version],
            environment,
        )?;

        let toolchain = SwiftToolchainResolver::inspect(Path::new(compiler_path), environment)?;
        SwiftToolchainPreferences {
            selected_path: Some(toolchain.root_url.to_string_lossy().into_owned()),
            ..SwiftToolchainPreferences::load(&self.directory)
        }
        .save(&self.directory)
        .map_err(|error| {
            SwiftToolchainError::InvalidInstallation(format!(
                "Could not store the selected toolchain: {error}"
            ))
        })?;
        Ok(toolchain)
    }

    pub fn remove(&self, version: &str) -> Result<(), SwiftToolchainError> {
        if !Self::releases()
            .iter()
            .any(|release| release.version == version)
        {
            return Err(SwiftToolchainError::UnsupportedPlatform);
        }
        {
            let installing = self
                .is_installing
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if *installing {
                return Err(SwiftToolchainError::InstallationInProgress);
            }
        }
        if let Some(selected) = SwiftToolchainPreferences::load(&self.directory).selected_path {
            let selected = PathBuf::from(selected);
            if selected.to_string_lossy().contains(&format!(
                "toolchains{}{}",
                std::path::MAIN_SEPARATOR,
                version
            )) {
                return Err(SwiftToolchainError::InvalidInstallation(
                    "Select another toolchain before removing the active toolchain.".to_string(),
                ));
            }
        }
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        let rustup =
            diffuse_script::dynamic_script::script_compiler::ScriptCompiler::resolve_executable_url(
                "rustup", &environment,
            )
            .map_err(|error| SwiftToolchainError::Unavailable(error.to_string()))?;
        Self::run_rustup(&rustup, &["toolchain", "uninstall", version], &environment)?;
        Ok(())
    }

    pub fn installed_versions(&self) -> Vec<String> {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        let Ok(rustup) =
            diffuse_script::dynamic_script::script_compiler::ScriptCompiler::resolve_executable_url(
                "rustup",
                &environment,
            )
        else {
            return Vec::new();
        };
        let Ok(listing) = Self::run_rustup(&rustup, &["toolchain", "list"], &environment) else {
            return Vec::new();
        };
        Self::releases()
            .into_iter()
            .map(|release| release.version)
            .filter(|version| {
                listing.lines().any(|line| {
                    line.trim()
                        .strip_prefix(version.as_str())
                        .is_some_and(|rest| rest.is_empty() || rest.starts_with(' '))
                })
            })
            .collect()
    }

    fn run_rustup(
        rustup: &Path,
        arguments: &[&str],
        environment: &BTreeMap<String, String>,
    ) -> Result<String, SwiftToolchainError> {
        let mut command = ProcessCommand::new(rustup).map_err(|error| {
            SwiftToolchainError::Unavailable(format!("Could not start rustup: {error}"))
        })?;
        command.directory = std::env::temp_dir();
        command.arguments = arguments.iter().map(|argument| argument.into()).collect();
        let mut launch_environment: BTreeMap<std::ffi::OsString, std::ffi::OsString> = environment
            .iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect();
        launch_environment.insert("LC_ALL".into(), "C".into());
        launch_environment.insert("LANG".into(), "C".into());
        command.environment = launch_environment;
        let limits = ProcessLimits {
            timeout: std::time::Duration::from_secs(900),
            output_bytes: 1_048_576,
            ..ProcessLimits::default()
        };
        let output = ProcessSession::spawn(&command, limits)
            .and_then(|session| session.collect())
            .map_err(|error| {
                SwiftToolchainError::InvalidInstallation(format!(
                    "Could not run rustup {}: {error}",
                    arguments.join(" ")
                ))
            })?;
        if output.code != 0 {
            let mut message = output.stderr;
            message.extend_from_slice(&output.stdout);
            return Err(SwiftToolchainError::InvalidInstallation(
                String::from_utf8_lossy(&message).into_owned(),
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }
}

/// Clears the in-progress flag however `install` exits.
struct InstallGuard<'a> {
    is_installing: &'a Mutex<bool>,
}

impl Drop for InstallGuard<'_> {
    fn drop(&mut self) {
        *self
            .is_installing
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = false;
    }
}
