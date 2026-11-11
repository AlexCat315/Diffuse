//! Stages the pinned Bun desktop runtime, ported from
//! `Tools/Developer/Sources/Build/PluginStaging/BunStaging.swift`.
//!
//! Bun is a build product of this checkout, never a developer prerequisite:
//! `cargo xtask plugins stage` downloads the archive pinned in
//! `PluginSDK/runtime.json`, verifies its SHA-256 and installs the executable
//! next to the plugin runtime's resources. `prepare` then builds the bundled
//! TypeScript plugins and the Bun runner, and `verify` runs the SDK checks.

use super::archive::SourceArchive;
use super::arguments::{FlagParser, absolute_path};
use crate::support::files;
use crate::support::repository;
use crate::support::sha256;
use crate::support::shell;
use crate::support::terminal::ToolError;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

pub const USAGE: &str = "cargo xtask plugins stage [--platform NAME] [--cache PATH] [--check]
cargo xtask plugins prepare
cargo xtask plugins verify
Stages the pinned Bun desktop runtime, builds TypeScript plugins, and verifies the public SDK.";

/// Resources of the `diffuse-plugin` crate, which is where the ported runtime
/// looks for `bun/bun[.exe]` and `bun-runner.js`.
const RESOURCES: &str = "crates/diffuse-plugin/Resources";

#[derive(Deserialize)]
struct BunCatalog {
    version: String,
    platforms: BTreeMap<String, BunPlatform>,
}

#[derive(Deserialize)]
struct BunPlatform {
    archive: String,
    sha256: String,
}

impl BunCatalog {
    fn read() -> Result<BunCatalog, ToolError> {
        let data = files::read(&repository::path("PluginSDK/runtime.json")).map_err(io_error)?;
        serde_json::from_slice(&data).map_err(|error| ToolError::message(error.to_string()))
    }
}

#[derive(Serialize, Deserialize)]
struct BunProvenance {
    version: String,
    platform: String,
    #[serde(rename = "archiveSHA256")]
    archive_sha256: String,
    #[serde(rename = "executableSHA256")]
    executable_sha256: String,
}

pub struct PluginStaging;

impl PluginStaging {
    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        let Some(operation) = arguments.first() else {
            return Err(ToolError::message(USAGE));
        };
        let flags = &arguments[1..];
        match operation.as_str() {
            "stage" => Self::stage(flags),
            "prepare" => {
                if !flags.is_empty() {
                    return Err(ToolError::message(USAGE));
                }
                Self::stage(&[])?;
                let bun = Self::binary();
                let root = repository::root();
                let environment: BTreeMap<String, String> = std::env::vars().collect();
                for command in [
                    vec!["install", "--frozen-lockfile", "--ignore-scripts"],
                    vec!["PluginSDK/src/build-bundled.ts"],
                    vec!["--no-macros", "PluginSDK/src/build-tools.ts"],
                    vec![
                        "build",
                        "PluginSDK/src/runner.ts",
                        "--target=bun",
                        "--format=esm",
                        "--outfile",
                        "crates/diffuse-plugin/Resources/bun-runner.js",
                    ],
                ] {
                    let mut arguments = vec![bun.to_string_lossy().into_owned()];
                    arguments.extend(command.into_iter().map(str::to_string));
                    shell::inherit(&arguments, Some(&root), &environment, None)?;
                }
                Ok(())
            }
            "verify" => {
                if !flags.is_empty() {
                    return Err(ToolError::message(USAGE));
                }
                Self::stage(&["--check".to_string()])?;
                let bun = Self::binary().to_string_lossy().into_owned();
                let root = repository::root();
                let environment: BTreeMap<String, String> = std::env::vars().collect();
                for command in [
                    vec!["run", "--cwd", "PluginSDK", "check"],
                    vec!["test", "PluginSDK/tests"],
                ] {
                    let mut arguments = vec![bun.clone()];
                    arguments.extend(command.into_iter().map(str::to_string));
                    shell::inherit(&arguments, Some(&root), &environment, None)?;
                }
                Ok(())
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                Ok(())
            }
            _ => Err(ToolError::message(USAGE)),
        }
    }

    /// Desktop host key used by `PluginSDK/runtime.json`.
    pub fn host() -> &'static str {
        const ARM: bool = cfg!(target_arch = "aarch64");
        if cfg!(target_os = "macos") {
            if ARM { "macos-arm64" } else { "macos-x86_64" }
        } else if cfg!(target_os = "windows") {
            if ARM {
                "windows-arm64"
            } else {
                "windows-x86_64"
            }
        } else if ARM {
            "linux-aarch64"
        } else {
            "linux-x86_64"
        }
    }

    /// Staged Bun executable inside the plugin runtime's resources.
    pub fn binary() -> PathBuf {
        let name = if cfg!(windows) { "bun.exe" } else { "bun" };
        repository::path(&format!("{RESOURCES}/bun/{name}"))
    }

    fn stage(arguments: &[String]) -> Result<(), ToolError> {
        let mut parser = FlagParser::new(arguments, &["--platform", "--cache"], &["--check"]);
        parser.parse()?;
        if parser.flags.contains("--help") {
            println!("{USAGE}");
            return Ok(());
        }
        if !parser.positionals.is_empty() {
            return Err(ToolError::message(USAGE));
        }
        let catalog = BunCatalog::read()?;
        let platform = parser
            .values
            .get("--platform")
            .cloned()
            .unwrap_or_else(|| Self::host().to_string());
        let Some(variant) = catalog.platforms.get(&platform) else {
            return Err(ToolError::message(format!(
                "Stage Bun on the matching desktop host; unsupported target {platform}"
            )));
        };
        if platform != Self::host() {
            return Err(ToolError::message(format!(
                "Stage Bun on the matching desktop host; unsupported target {platform}"
            )));
        }
        let executable = Self::binary();
        let ready = Self::ready(&executable, &catalog.version, &platform, &variant.sha256);
        if parser.flags.contains("--check") {
            if !ready {
                return Err(ToolError::message(format!(
                    "Bun {} is not staged; run cargo xtask plugins prepare",
                    catalog.version
                )));
            }
            return Ok(());
        }
        if ready {
            return Ok(());
        }
        let cache = parser
            .values
            .get("--cache")
            .map(|path| absolute_path(path))
            .unwrap_or_else(|| repository::path("build/native/bun"));
        let installed = SourceArchive::fetch(
            &format!(
                "https://github.com/oven-sh/bun/releases/download/bun-v{}/{}.zip",
                catalog.version, variant.archive
            ),
            &variant.sha256,
            &cache,
        )?;
        let source = installed.join(
            executable
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default(),
        );
        if let Some(parent) = executable.parent() {
            files::directory(parent).map_err(io_error)?;
        }
        files::copy(&source, &executable).map_err(io_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755))
                .map_err(io_error)?;
        }
        let provenance = BunProvenance {
            version: catalog.version,
            platform,
            archive_sha256: variant.sha256.clone(),
            executable_sha256: sha256::hex_file(&executable).map_err(io_error)?,
        };
        let destination = executable
            .parent()
            .map(|parent| parent.join("runtime.json"))
            .unwrap_or_else(|| PathBuf::from("runtime.json"));
        let data = serde_json::to_vec(&provenance)
            .map_err(|error| ToolError::message(error.to_string()))?;
        files::write(&destination, &data).map_err(io_error)
    }

    /// True when the staged executable matches the pinned catalog entry and the
    /// recorded archive checksum.
    pub fn ready(executable: &Path, version: &str, platform: &str, archive: &str) -> bool {
        let Some(parent) = executable.parent() else {
            return false;
        };
        let Ok(data) = files::read(&parent.join("runtime.json")) else {
            return false;
        };
        let Ok(record) = serde_json::from_slice::<BunProvenance>(&data) else {
            return false;
        };
        record.version == version
            && record.platform == platform
            && record.archive_sha256 == archive
            && sha256::hex_file(executable)
                .map(|hex| hex == record.executable_sha256)
                .unwrap_or(false)
    }
}

fn io_error(error: io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let directory =
            std::env::temp_dir().join(format!("diffuse-bun-staging-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn the_host_key_matches_the_current_platform() {
        let host = PluginStaging::host();
        let arch_arm = cfg!(target_arch = "aarch64");
        let expected = if cfg!(target_os = "macos") {
            if arch_arm {
                "macos-arm64"
            } else {
                "macos-x86_64"
            }
        } else if cfg!(target_os = "windows") {
            if arch_arm {
                "windows-arm64"
            } else {
                "windows-x86_64"
            }
        } else if arch_arm {
            "linux-aarch64"
        } else {
            "linux-x86_64"
        };
        assert_eq!(host, expected);
    }

    #[test]
    fn the_executable_lives_in_the_plugin_runtime_resources() {
        let binary = PluginStaging::binary();
        assert!(binary.ends_with(if cfg!(windows) {
            "crates/diffuse-plugin/Resources/bun/bun.exe"
        } else {
            "crates/diffuse-plugin/Resources/bun/bun"
        }));
    }

    #[test]
    fn the_catalog_is_desktop_only_and_requires_integrity() {
        let catalog = BunCatalog::read().unwrap();
        assert_eq!(catalog.version, "1.4.4");
        let mut platforms: Vec<&str> = catalog.platforms.keys().map(String::as_str).collect();
        platforms.sort();
        assert_eq!(
            platforms,
            [
                "linux-aarch64",
                "linux-x86_64",
                "macos-arm64",
                "macos-x86_64",
                "windows-arm64",
                "windows-x86_64"
            ]
        );
        for variant in catalog.platforms.values() {
            assert_eq!(variant.sha256.len(), 64);
            assert!(variant.archive.starts_with("bun-"));
        }
        let missing = std::env::temp_dir().join(format!(
            "diffuse-bun-staging-{}-missing-catalog",
            std::process::id()
        ));
        assert!(!PluginStaging::ready(
            &missing,
            &catalog.version,
            PluginStaging::host(),
            "wrong"
        ));
    }

    #[test]
    fn readiness_requires_the_recorded_executable_checksum() {
        let directory = scratch("ready");
        let executable = directory.join(if cfg!(windows) { "bun.exe" } else { "bun" });
        std::fs::write(&executable, b"staged").unwrap();
        let digest = sha256::hex_file(&executable).unwrap();
        let provenance = BunProvenance {
            version: "1.4.4".to_string(),
            platform: PluginStaging::host().to_string(),
            archive_sha256: "archive".to_string(),
            executable_sha256: digest.clone(),
        };
        std::fs::write(
            directory.join("runtime.json"),
            serde_json::to_vec(&provenance).unwrap(),
        )
        .unwrap();

        assert!(PluginStaging::ready(
            &executable,
            "1.4.4",
            PluginStaging::host(),
            "archive"
        ));
        assert!(!PluginStaging::ready(
            &executable,
            "1.4.5",
            PluginStaging::host(),
            "archive"
        ));
        assert!(!PluginStaging::ready(
            &executable,
            "1.4.4",
            PluginStaging::host(),
            "other"
        ));

        std::fs::write(&executable, b"tampered").unwrap();
        assert!(!PluginStaging::ready(
            &executable,
            "1.4.4",
            PluginStaging::host(),
            "archive"
        ));
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_missing_provenance_is_never_ready() {
        let directory = scratch("missing");
        let executable = directory.join("bun");
        std::fs::write(&executable, b"staged").unwrap();
        assert!(!PluginStaging::ready(
            &executable,
            "1.4.4",
            PluginStaging::host(),
            "archive"
        ));
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn provenance_uses_the_swift_field_names() {
        let provenance = BunProvenance {
            version: "1.4.4".to_string(),
            platform: "linux-x86_64".to_string(),
            archive_sha256: "archive".to_string(),
            executable_sha256: "executable".to_string(),
        };
        let json: serde_json::Value =
            serde_json::from_slice(&serde_json::to_vec(&provenance).unwrap()).unwrap();
        assert_eq!(json["archiveSHA256"], "archive");
        assert_eq!(json["executableSHA256"], "executable");
        assert_eq!(json["version"], "1.4.4");
    }

    #[test]
    fn unknown_operations_print_usage_as_an_error() {
        assert_eq!(
            PluginStaging::run(&["install".to_string()])
                .unwrap_err()
                .to_string(),
            USAGE
        );
        assert_eq!(PluginStaging::run(&[]).unwrap_err().to_string(), USAGE);
    }
}
