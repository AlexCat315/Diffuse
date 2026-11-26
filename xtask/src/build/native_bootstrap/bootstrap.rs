//! Stages Diffuse's OpenEXR/Imath archive and the pinned plugin runtime.
//! Cove's native libraries are built by its Rust build scripts.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::build::plugin_staging::bun_staging::PluginStaging;
use crate::support::files;
use crate::support::repository;
use crate::support::shell;
use crate::support::terminal::ToolError;

pub enum Bootstrap {}

impl Bootstrap {
    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        let force = arguments.iter().any(|argument| argument == "--force");
        let root = repository::root();
        let source = root.join("Engine/third-party");
        let build = root.join("Engine/build/native");
        let vendor = root.join(
            std::env::var_os("DIFFUSE_NATIVE_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("vendor")),
        );

        let mut environment: BTreeMap<String, String> = std::env::vars().collect();
        environment.insert("MIMALLOC_DISABLE_REDIRECT".into(), "1".into());
        #[cfg(windows)]
        crate::support::windows_build_environment::activate(&mut environment)?;

        let cmake = shell::executable("cmake", &environment)
            .ok_or_else(|| ToolError::message("CMake 3.20 or later is required on PATH."))?;
        for dependency in ["imath", "openexr"] {
            if !source.join(dependency).join("CMakeLists.txt").is_file() {
                return Err(ToolError::message(format!(
                    "Missing Engine/third-party/{dependency}. Run git submodule update --init --recursive."
                )));
            }
        }

        if force {
            // Invalidate ExternalProject stamps so CMake rebuilds the pinned sources.
            files::remove(&build).map_err(|error| {
                ToolError::message(format!("could not discard {}: {error}", build.display()))
            })?;
        }

        let cmake = cmake.to_string_lossy().into_owned();
        let build = build.to_string_lossy().into_owned();
        shell::inherit(
            &[
                cmake.clone(),
                "-S".into(),
                source.to_string_lossy().into_owned(),
                "-B".into(),
                build.clone(),
                "-DCMAKE_BUILD_TYPE=Release".into(),
                format!("-DCOVE_VENDOR_DIR={}", vendor.display()),
            ],
            Some(&root),
            &environment,
            None,
        )?;
        shell::inherit(
            &[
                cmake.clone(),
                "--build".into(),
                build.clone(),
                "--parallel".into(),
                "--config".into(),
                "Release".into(),
            ],
            Some(&root),
            &environment,
            None,
        )?;
        shell::inherit(
            &[
                cmake,
                "--install".into(),
                build,
                "--config".into(),
                "Release".into(),
            ],
            Some(&root),
            &environment,
            None,
        )?;
        PluginStaging::run(&["stage".into()])
    }
}
