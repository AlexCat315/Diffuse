//! `Editor/Sources/GameRuntime/PlayerInstallValidator.swift`.

use std::fmt;
use std::path::{Component, Path, PathBuf};

use cove_platform::ResourceBundle;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlayerInstallValidationError {
    ExecutableLocationUnavailable,
    MissingComponents(Vec<String>),
}

impl fmt::Display for PlayerInstallValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlayerInstallValidationError::ExecutableLocationUnavailable => formatter
                .write_str("CovePlayer installation validation could not locate the executable."),
            PlayerInstallValidationError::MissingComponents(components) => {
                write!(
                    formatter,
                    "CovePlayer installation is incomplete; missing: {}",
                    components.join(", ")
                )
            }
        }
    }
}

impl std::error::Error for PlayerInstallValidationError {}

/// Validates the resource layout used by both release archives and exported games.
pub struct PlayerInstallValidator;

impl PlayerInstallValidator {
    pub const RESOURCE_BUNDLE_BASES: [&'static str; 5] = [
        "DiffuseEditor_EditorCore",
        "DiffuseRuntime_RenderBackend",
        "CoveUI_CoveUI",
        "CoveUICompose_CoveUICompose",
        "CoveUI_CoveUIWorkspace",
    ];

    /// Swift's defaults: the running executable and `CommandLine.arguments`.
    pub fn validate_layout_default() -> Result<String, PlayerInstallValidationError> {
        let arguments: Vec<String> = std::env::args().collect();
        Self::validate_layout(None, std::env::current_exe().ok().as_deref(), &arguments)
    }

    pub fn validate_layout(
        executable_url: Option<&Path>,
        bundle_executable_url: Option<&Path>,
        arguments: &[String],
    ) -> Result<String, PlayerInstallValidationError> {
        let Some(executable_url) = executable_url
            .or(bundle_executable_url)
            .map(Path::to_path_buf)
            .or_else(|| arguments.first().map(PathBuf::from))
        else {
            return Err(PlayerInstallValidationError::ExecutableLocationUnavailable);
        };
        let standardized_executable = standardize(&executable_url);
        let executable_directory = standardized_executable
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let contents_directory = executable_directory
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let is_application_bundle = executable_directory
            .file_name()
            .is_some_and(|name| name == "MacOS")
            && contents_directory
                .file_name()
                .is_some_and(|name| name == "Contents")
            && contents_directory
                .parent()
                .and_then(Path::extension)
                .is_some_and(|extension| extension == "app");
        let resource_root = if is_application_bundle {
            contents_directory.join("Resources")
        } else {
            executable_directory.clone()
        };

        let mut missing: Vec<String> = Vec::new();
        if !is_runnable_file(&standardized_executable)
            && let Some(name) = standardized_executable.file_name()
        {
            missing.push(name.to_string_lossy().into_owned());
        }
        if is_application_bundle {
            let info_plist = contents_directory.join("Info.plist");
            if !is_valid_application_info_plist(&info_plist) {
                missing.push("Contents/Info.plist".to_string());
            }
        }
        for base in Self::RESOURCE_BUNDLE_BASES {
            if ResourceBundle::locate(&[base], std::slice::from_ref(&resource_root)).is_none() {
                missing.push(format!("{base}.{{bundle,resources}}"));
            }
        }
        if !missing.is_empty() {
            missing.sort();
            return Err(PlayerInstallValidationError::MissingComponents(missing));
        }
        Ok(format!(
            "CovePlayer installation validation passed ({} resource bundles)",
            Self::RESOURCE_BUNDLE_BASES.len()
        ))
    }
}

fn standardize(path: &Path) -> PathBuf {
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn is_runnable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if metadata.is_dir() {
        return false;
    }
    #[cfg(windows)]
    {
        true
    }
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
}

fn is_valid_application_info_plist(path: &Path) -> bool {
    diffuse_kernel::plist::is_application_info_plist(path, None, "APPL")
}
