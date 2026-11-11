//! Translation of
//! Tools/Developer/Sources/Build/NativeBootstrap/Bootstrap.swift.
//!
//! Mirrors `bootstrap.py` step by step: environment, SDK setup, readiness
//! gates, then cmake. The Swift media-staging step is gone because
//! `MediaStaging` is a `removed` row — FFmpeg is staged by Cove.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::build::plugin_staging::bun_staging::PluginStaging;
use crate::support::files;
use crate::support::repository;
use crate::support::shell;
use crate::support::terminal::ToolError;
use crate::support::windows_build_environment;

pub enum Bootstrap {}

impl Bootstrap {
    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        let force = arguments.iter().any(|argument| argument == "--force");
        let root = repository::root();
        let sdk_root = std::env::var_os("COVE_SDK_ROOT")
            .map(PathBuf::from)
            .map(|path| std::path::absolute(&path).unwrap_or(path))
            .unwrap_or_else(|| root.join("CoveUI"));

        // mimalloc must not redirect the CRT allocator while the graphics
        // libraries and their consumers are built.
        let mut environment: BTreeMap<String, String> = std::env::vars().collect();
        environment.insert("MIMALLOC_DISABLE_REDIRECT".to_string(), "1".to_string());
        #[cfg(windows)]
        windows_build_environment::activate(&mut environment)?;

        let sdk_command = sdk_executable(&sdk_root);
        shell::inherit(
            &[
                sdk_command.to_string_lossy().into_owned(),
                "setup".to_string(),
                "--sdk-root".to_string(),
                sdk_root.to_string_lossy().into_owned(),
            ],
            None,
            &environment,
            None,
        )?;

        // ── Sentinels ─────────────────────────────────────────────────────
        let engine_done = root.join("Engine/vendor/ocio_openexr.artifactbundle");
        let cove_ui_done = sdk_root.join("vendor/CFreeType.artifactbundle");
        let terminal_done = sdk_root.join("vendor/GhosttyVt.artifactbundle");

        let mut bun_ready =
            PluginStaging::run(&["stage".to_string(), "--check".to_string()]).is_ok();
        if !bun_ready {
            PluginStaging::run(&["stage".to_string()])?;
            bun_ready = true;
        }

        if !force
            && engine_done.exists()
            && cove_ui_done.exists()
            && terminal_done.exists()
            && bun_ready
        {
            println!(
                "Native deps already built. Run `cove-dev native-bootstrap --force` to rebuild."
            );
            return Ok(());
        }

        // ── cmake ─────────────────────────────────────────────────────────
        let Some(cmake) = shell::executable("cmake", &environment) else {
            return Err(ToolError::message(
                "cmake not found on PATH — install CMake 3.20+ first.",
            ));
        };

        // `--force` must invalidate ExternalProject configure/build/install
        // stamps too; rerunning CMake alone can reuse libs from an older
        // submodule.
        if force {
            let build = root.join("Engine").join("build/native");
            files::remove(&build).map_err(|error| {
                ToolError::message(format!("could not discard {}: {error}", build.display()))
            })?;
        }

        // ── Engine ────────────────────────────────────────────────────────
        let engine_source = root.join("Engine/third-party");
        let engine_build = root.join("Engine/build/native");
        let install_prefix = std::env::temp_dir().join("cove-native-install");

        println!("\n[ Engine ]");
        shell::inherit(
            &[
                cmake.to_string_lossy().into_owned(),
                "-S".to_string(),
                engine_source.to_string_lossy().into_owned(),
                "-B".to_string(),
                engine_build.to_string_lossy().into_owned(),
                "-DCMAKE_BUILD_TYPE=Release".to_string(),
            ],
            None,
            &environment,
            None,
        )?;
        // `--config Release` is required by multi-config generators (Visual
        // Studio): they ignore CMAKE_BUILD_TYPE and otherwise default to Debug,
        // which triggers MSVC's parallel PDB server (C1090) on static-lib
        // builds. Harmless on single-config generators.
        shell::inherit(
            &[
                cmake.to_string_lossy().into_owned(),
                "--build".to_string(),
                engine_build.to_string_lossy().into_owned(),
                "--parallel".to_string(),
                "--config".to_string(),
                "Release".to_string(),
            ],
            None,
            &environment,
            None,
        )?;
        shell::inherit(
            &[
                cmake.to_string_lossy().into_owned(),
                "--install".to_string(),
                engine_build.to_string_lossy().into_owned(),
                "--prefix".to_string(),
                install_prefix.to_string_lossy().into_owned(),
                "--config".to_string(),
                "Release".to_string(),
            ],
            None,
            &environment,
            None,
        )?;

        println!("\nDone. Run: ./cove run Editor --mac");
        Ok(())
    }
}

#[cfg(windows)]
fn sdk_executable(sdk_root: &Path) -> PathBuf {
    let binary = sdk_root.join("cove.exe");
    if binary.exists() {
        binary
    } else {
        sdk_root.join("cove.cmd")
    }
}

#[cfg(not(windows))]
fn sdk_executable(sdk_root: &Path) -> PathBuf {
    sdk_root.join("cove")
}
