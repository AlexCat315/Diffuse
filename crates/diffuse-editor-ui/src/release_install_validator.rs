//! `Editor/Sources/EditorUI/ReleaseInstallValidator.swift`.

use std::fmt;
use std::path::{Component, Path, PathBuf};

use cove_platform::ResourceBundle;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorInstallValidationError {
    ExecutableLocationUnavailable,
    MissingComponents(Vec<String>),
}

impl fmt::Display for EditorInstallValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EditorInstallValidationError::ExecutableLocationUnavailable => formatter
                .write_str("Editor installation validation could not locate the executable."),
            EditorInstallValidationError::MissingComponents(components) => write!(
                formatter,
                "Editor installation is incomplete; missing: {}",
                components.join(", ")
            ),
        }
    }
}

impl std::error::Error for EditorInstallValidationError {}

pub struct EditorInstallValidator;

impl EditorInstallValidator {
    pub const RESOURCE_BUNDLE_BASES: [&'static str; 6] = [
        "DiffuseEditor_EditorUI",
        "DiffuseEditor_EditorCore",
        "DiffuseRuntime_RenderBackend",
        "CoveUI_CoveUI",
        "CoveUICompose_CoveUICompose",
        "CoveUI_CoveUIWorkspace",
    ];

    /// Swift's defaults: running executable, `CommandLine.arguments`, host OS.
    pub fn validate_editor_layout_default() -> Result<String, EditorInstallValidationError> {
        let arguments: Vec<String> = std::env::args().collect();
        Self::validate_editor_layout(
            None,
            std::env::current_exe().ok().as_deref(),
            &arguments,
            cfg!(windows),
        )
    }

    pub fn validate_editor_layout(
        executable_url: Option<&Path>,
        bundle_executable_url: Option<&Path>,
        arguments: &[String],
        is_windows: bool,
    ) -> Result<String, EditorInstallValidationError> {
        let Some(executable_url) = executable_url
            .or(bundle_executable_url)
            .map(Path::to_path_buf)
            .or_else(|| arguments.first().map(PathBuf::from))
        else {
            return Err(EditorInstallValidationError::ExecutableLocationUnavailable);
        };
        let standardized_executable = standardize(&executable_url);
        let executable_directory = standardized_executable
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let suffix = if is_windows { ".exe" } else { "" };
        let contents_directory = executable_directory
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let is_application_bundle = !is_windows
            && executable_directory
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

        let required_files: Vec<(String, PathBuf)> = if is_application_bundle {
            vec![
                (
                    "Contents/MacOS/EditorApp".to_string(),
                    standardized_executable.clone(),
                ),
                (
                    "Contents/MacOS/CovePlayer".to_string(),
                    executable_directory.join("CovePlayer"),
                ),
                (
                    "Contents/Helpers/DiffusePluginHost".to_string(),
                    contents_directory.join("Helpers").join("DiffusePluginHost"),
                ),
                (
                    "Contents/Helpers/DiffuseMCP".to_string(),
                    contents_directory.join("Helpers").join("DiffuseMCP"),
                ),
            ]
        } else {
            vec![
                (
                    format!("EditorApp{suffix}"),
                    executable_directory.join(format!("EditorApp{suffix}")),
                ),
                (
                    format!("CovePlayer{suffix}"),
                    executable_directory.join(format!("CovePlayer{suffix}")),
                ),
                (
                    format!("Tools/DiffusePluginHost{suffix}"),
                    executable_directory
                        .join("Tools")
                        .join(format!("DiffusePluginHost{suffix}")),
                ),
                (
                    format!("Tools/DiffuseMCP{suffix}"),
                    executable_directory
                        .join("Tools")
                        .join(format!("DiffuseMCP{suffix}")),
                ),
            ]
        };
        let mut missing: Vec<String> = required_files
            .into_iter()
            .filter_map(|(label, url)| (!is_runnable_file(&url, is_windows)).then_some(label))
            .collect();
        if is_application_bundle {
            let info_plist = contents_directory.join("Info.plist");
            if !diffuse_kernel::plist::is_application_info_plist(
                &info_plist,
                Some("EditorApp"),
                "APPL",
            ) {
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
            return Err(EditorInstallValidationError::MissingComponents(missing));
        }
        Ok(format!(
            "Editor installation validation passed (4 executables, {} resource bundles)",
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

fn is_regular_file(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| !metadata.is_dir())
}

fn is_runnable_file(path: &Path, is_windows: bool) -> bool {
    if !is_regular_file(path) {
        return false;
    }
    if is_windows {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|metadata| metadata.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        false
    }
}
