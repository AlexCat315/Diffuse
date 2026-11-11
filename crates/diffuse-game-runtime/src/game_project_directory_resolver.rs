//! Translation of Editor/Sources/GameRuntime/GameProjectDirectoryResolver.swift.
//!
//! Resolves the project consumed by CovePlayer in a deterministic priority order.
//! Besides explicit CLI/environment configuration, it recognizes both the macOS
//! app resource layout and the portable `Export/Player/CovePlayer` layout.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub struct GameProjectDirectoryResolver;

impl GameProjectDirectoryResolver {
    pub fn resolve(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
        bundle_resource_url: Option<&Path>,
        executable_url: Option<&Path>,
        current_directory_url: &Path,
    ) -> Option<String> {
        if let Some(index) = arguments
            .iter()
            .position(|argument| argument == "--project")
            && let Some(value) = arguments.get(index + 1)
            && !value.is_empty()
        {
            return Some(value.clone());
        }
        if let Some(environment_path) = environment.get("COVE_PROJECT_DIR")
            && !environment_path.is_empty()
        {
            return Some(environment_path.clone());
        }
        if let Some(bundle_resource_url) = bundle_resource_url {
            let bundled_project = bundle_resource_url.join("CoveProject");
            if Self::is_project_directory(&bundled_project) {
                return Some(bundled_project.to_string_lossy().into_owned());
            }
        }
        let discovered_executable_url = executable_url.map(Path::to_path_buf).or_else(|| {
            arguments
                .first()
                .filter(|argument| !argument.is_empty())
                .map(PathBuf::from)
        });
        if let Some(executable_url) = discovered_executable_url {
            let executable_directory = executable_url.parent()?;
            // Portable exports keep the executable under `<project>/Player/`.
            let portable_project = executable_directory
                .parent()
                .unwrap_or(executable_directory);
            if Self::is_project_directory(portable_project) {
                return Some(portable_project.to_string_lossy().into_owned());
            }
            if Self::is_project_directory(executable_directory) {
                return Some(executable_directory.to_string_lossy().into_owned());
            }
        }
        if Self::is_project_directory(current_directory_url) {
            Some(current_directory_url.to_string_lossy().into_owned())
        } else {
            None
        }
    }

    /// `resolve(arguments:environment:bundleResourceURL:executableURL:currentDirectoryURL:)`
    /// with the process defaults Swift reads from `CommandLine`, `ProcessInfo` and
    /// `Bundle.main`. Rust has no resource bundle, so `bundle_resource_url` stays
    /// `None`; the portable layout is found through the executable path.
    pub fn resolve_default() -> Option<String> {
        let arguments: Vec<String> = std::env::args().collect();
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        let executable_url = std::env::current_exe().ok();
        let current_directory = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        Self::resolve(
            &arguments,
            &environment,
            None,
            executable_url.as_deref(),
            &current_directory,
        )
    }

    fn is_project_directory(url: &Path) -> bool {
        url.join("build.json").is_file()
    }
}
