//! `Editor/Sources/EditorCore/Scripting/Dynamic/ProjectCompiledScripts.swift`.
//!
//! D1 rewrite: project scripts are a Rust cdylib crate under `Scripts/` that
//! depends on `diffuse-script-api`. Host toolchain discovery (`swiftc`, Clang
//! module maps, SDK include paths) is replaced by cargo: the build only needs a
//! cargo executable plus the environment it runs in.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::tool_locator::ProcessEnvironment;
use diffuse_assets::project_resource_walker;
use diffuse_assets::swift_json;
use diffuse_capability::release::sha256::CapabilityDigest;
use diffuse_script::dynamic_script::script_compiler::{ScriptCompileError, ScriptCompiler};
use serde::{Deserialize, Serialize};

use crate::scene::project_exporter::ProjectExporterError;
use crate::scripting::assets::script_asset_registry::{
    ResolvedScriptAsset, ScriptAssetRegistry, ScriptAssetRegistryError,
};
use crate::scripting::static_::project_static_scripts::ProjectStaticScripts;
use crate::scripting::toolchain::preferences::SwiftToolchainPreferences;
use crate::scripting::toolchain::resolution::SwiftToolchainResolver;

/// How compiled gameplay reaches the player.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectScriptDelivery {
    /// Staged as a loadable library beside the player data.
    DynamicLibrary,
    /// Sources are compiled into the player itself (Android APK builds).
    StaticLink,
}

/// Host-owned compiler configuration. It is never read from project files.
///
/// Swift carried Swift module/modulemap/include paths plus a `swiftc` path. D1
/// has neither: scripts depend on `diffuse-script-api` only, and cargo resolves
/// the rest of the dependency graph, so the configuration is the cargo
/// executable, the environment it runs in, and the delivery mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectScriptBuildConfiguration {
    pub delivery: ProjectScriptDelivery,
    pub cargo_path: String,
    pub environment: BTreeMap<String, String>,
}

impl ProjectScriptBuildConfiguration {
    /// Swift's `delivery: .dynamicLibrary` default.
    pub fn new(cargo_path: impl Into<String>, environment: BTreeMap<String, String>) -> Self {
        Self::with_delivery(
            ProjectScriptDelivery::DynamicLibrary,
            cargo_path,
            environment,
        )
    }

    pub fn with_delivery(
        delivery: ProjectScriptDelivery,
        cargo_path: impl Into<String>,
        environment: BTreeMap<String, String>,
    ) -> Self {
        ProjectScriptBuildConfiguration {
            delivery,
            cargo_path: cargo_path.into(),
            environment,
        }
    }

    /// Finds the cargo a development host builds its scripts with: the Rust
    /// toolchain next to the host (or the one its preferences/env select),
    /// then a `cargo` beside the executable, then `PATH`.
    ///
    /// Swift used this entry point to locate SDK module directories beside the
    /// executable; the Rust equivalent is locating the toolchain's cargo.
    pub fn discover(executable_url: &Path, environment: &BTreeMap<String, String>) -> Self {
        let preferences = SwiftToolchainPreferences::load_with_default();
        if let Ok(toolchain) = SwiftToolchainResolver::resolve(None, environment, &preferences) {
            let cargo = ProcessEnvironment::value("CARGO", &toolchain.environment)
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| cargo_executable_name().to_string());
            return Self::new(cargo, toolchain.environment);
        }
        let beside_host = executable_url
            .parent()
            .map(|directory| directory.join(cargo_executable_name()))
            .filter(|candidate| candidate.is_file());
        if let Some(cargo) = beside_host {
            return Self::new(cargo.to_string_lossy().into_owned(), environment.clone());
        }
        let cargo = ScriptCompiler::resolve_executable_url("cargo", environment)
            .map(|url| url.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "cargo".to_string());
        Self::new(cargo, environment.clone())
    }

    /// `discover(for:)` with the process environment.
    pub fn discover_default(executable_url: &Path) -> Self {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::discover(executable_url, &environment)
    }

    /// Swift callers asked whether `engineModulePaths` was empty to decide if
    /// gameplay can be compiled; D1 asks the same question of cargo.
    pub fn has_toolchain(&self) -> bool {
        ScriptCompiler::resolve_executable_url(&self.cargo_path, &self.environment).is_ok()
    }
}

fn cargo_executable_name() -> &'static str {
    if cfg!(windows) { "cargo.exe" } else { "cargo" }
}

/// Precompiled game code: Player loads these artifacts without any toolchain.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCompiledScripts {
    pub version: i64,
    pub target: String,
    pub entries: Vec<ProjectCompiledScriptEntry>,
}

impl ProjectCompiledScripts {
    pub const RELATIVE_PATH: &'static str = "Scripts/compiled-scripts.json";
    pub const CURRENT_VERSION: i64 = 1;

    pub fn current_target() -> String {
        #[cfg(target_os = "macos")]
        let platform = "macos";
        #[cfg(target_os = "linux")]
        let platform = "linux";
        #[cfg(target_os = "windows")]
        let platform = "windows";
        #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
        let platform = "unknown";

        #[cfg(target_arch = "aarch64")]
        let architecture = "arm64";
        #[cfg(target_arch = "x86_64")]
        let architecture = "x86_64";
        #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
        let architecture = "unknown";

        format!("{platform}-{architecture}")
    }

    pub fn new(entries: Vec<ProjectCompiledScriptEntry>) -> Self {
        Self::with_target(entries, Self::CURRENT_VERSION, Self::current_target())
    }

    pub fn with_target(
        entries: Vec<ProjectCompiledScriptEntry>,
        version: i64,
        target: String,
    ) -> Self {
        ProjectCompiledScripts {
            version,
            target,
            entries,
        }
    }

    pub fn digest(data: &[u8]) -> String {
        CapabilityDigest::sha256(data)
    }

    /// Builds the project's `Scripts/` gameplay into `into`.
    ///
    /// Static delivery stages the sources for a player-side build. Dynamic
    /// delivery runs cargo once for the whole crate and publishes one shared
    /// cdylib, because Rust exposes every script of a crate from the same
    /// library; each script asset still gets its own manifest entry so scene
    /// bindings keep Swift's identifier granularity.
    pub(crate) fn build(
        from: &Path,
        configuration: Option<&ProjectScriptBuildConfiguration>,
        into: &Path,
    ) -> Result<BTreeSet<String>, ProjectCompiledScriptsError> {
        let scripts_directory = from.join("Scripts");
        if !scripts_directory.is_dir() {
            return Ok(BTreeSet::new());
        }
        let sources = Self::sources(&scripts_directory)?;
        if sources.is_empty() {
            return Ok(BTreeSet::new());
        }
        let configuration =
            configuration.ok_or(ProjectExporterError::MissingScriptBuildConfiguration)?;
        let registry = ScriptAssetRegistry::new(&from.to_string_lossy());
        let assets = registry.resolve(sources)?;
        if configuration.delivery == ProjectScriptDelivery::StaticLink {
            return Ok(ProjectStaticScripts::stage(&assets, into)?);
        }
        Self::build_dynamic(&scripts_directory, &assets, configuration, into)
    }

    fn build_dynamic(
        scripts_directory: &Path,
        assets: &[ResolvedScriptAsset],
        configuration: &ProjectScriptBuildConfiguration,
        into: &Path,
    ) -> Result<BTreeSet<String>, ProjectCompiledScriptsError> {
        // A cargo manifest is the Rust form of Swift's "built Engine modules
        // and a compiler": without it the crate cannot be compiled.
        if !scripts_directory.join("Cargo.toml").is_file() {
            return Err(ProjectExporterError::MissingScriptBuildConfiguration.into());
        }
        let alias_counts = alias_counts(assets);
        let compiled_directory = into.join("Scripts").join("Compiled");
        let mut compiler = ScriptCompiler::new(&compiled_directory);
        compiler.cargo_path = configuration.cargo_path.clone();
        compiler.environment = configuration.environment.clone();
        let result = compiler.compile(scripts_directory, "scripts", None)?;
        let library = PathBuf::from(&result.output_path);
        let library_name = library
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .ok_or_else(|| {
                ProjectCompiledScriptsError::Io(std::io::Error::other(format!(
                    "cargo produced an artifact without a file name: {}",
                    library.display()
                )))
            })?;
        let digest = Self::digest(&std::fs::read(&library)?);
        let library_path = format!("Scripts/Compiled/{library_name}");
        let entries: Vec<ProjectCompiledScriptEntry> = assets
            .iter()
            .map(|asset| {
                let identifier = asset.id.runtime_identifier();
                ProjectCompiledScriptEntry {
                    display_name: display_name(&asset.url),
                    legacy_identifiers: asset
                        .legacy_identifiers
                        .iter()
                        .filter(|legacy| {
                            **legacy != identifier && alias_counts.get(*legacy).copied() == Some(1)
                        })
                        .cloned()
                        .collect(),
                    identifier,
                    library_path: library_path.clone(),
                    sha256: digest.clone(),
                }
            })
            .collect();
        let document = ProjectCompiledScripts::new(entries);
        let text = swift_json::to_sorted_pretty(&document)?;
        let manifest_url = into.join(Self::RELATIVE_PATH);
        if let Some(parent) = manifest_url.parent() {
            std::fs::create_dir_all(parent)?;
        }
        AtomicFile::write(text.as_bytes(), &manifest_url, Access::Inherit)?;
        Ok(document
            .entries
            .iter()
            .flat_map(|entry| {
                std::iter::once(entry.identifier.clone()).chain(entry.legacy_identifiers.clone())
            })
            .collect())
    }

    /// Rust sources of the `Scripts/` crate. Cargo compiles `Scripts/src`, so
    /// only what lives there becomes a script asset.
    fn sources(scripts_directory: &Path) -> Result<Vec<PathBuf>, ProjectCompiledScriptsError> {
        let source_root = scripts_directory.join("src");
        if !source_root.is_dir() {
            return Ok(Vec::new());
        }
        let mut sources: Vec<PathBuf> =
            project_resource_walker::files(&source_root, false, |_| false)?
                .into_iter()
                .filter(|url| is_rust_source(url))
                .collect();
        sources.sort_by(|left, right| {
            file_name_lower(left)
                .cmp(&file_name_lower(right))
                .then_with(|| left.cmp(right))
        });
        Ok(sources)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCompiledScriptEntry {
    pub identifier: String,
    pub display_name: String,
    pub legacy_identifiers: Vec<String>,
    pub library_path: String,
    pub sha256: String,
}

impl ProjectCompiledScriptEntry {
    pub fn new(
        identifier: impl Into<String>,
        display_name: impl Into<String>,
        legacy_identifiers: Vec<String>,
        library_path: impl Into<String>,
        sha256: impl Into<String>,
    ) -> Self {
        ProjectCompiledScriptEntry {
            identifier: identifier.into(),
            display_name: display_name.into(),
            legacy_identifiers,
            library_path: library_path.into(),
            sha256: sha256.into(),
        }
    }
}

fn alias_counts(assets: &[ResolvedScriptAsset]) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for asset in assets {
        for legacy in &asset.legacy_identifiers {
            *counts.entry(legacy.clone()).or_default() += 1;
        }
    }
    counts
}

fn display_name(url: &Path) -> String {
    url.file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn is_rust_source(url: &Path) -> bool {
    url.extension()
        .map(|extension| extension.to_string_lossy().eq_ignore_ascii_case("rs"))
        .unwrap_or(false)
}

fn file_name_lower(url: &Path) -> String {
    url.file_name()
        .map(|name| name.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

#[derive(Debug, thiserror::Error)]
pub enum ProjectCompiledScriptsError {
    #[error(transparent)]
    Exporter(#[from] ProjectExporterError),
    #[error(transparent)]
    Registry(#[from] ScriptAssetRegistryError),
    #[error(transparent)]
    Compile(#[from] ScriptCompileError),
    #[error(transparent)]
    Walker(#[from] project_resource_walker::ProjectResourceWalkerError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Encode(#[from] swift_json::SwiftJsonError),
}
