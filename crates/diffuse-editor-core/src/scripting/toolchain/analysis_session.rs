//! `Editor/Sources/EditorCore/Scripting/Toolchain/AnalysisSession.swift`.
//!
//! D1 rewrite: the analysis session configures `rust-analyzer` from the cargo
//! toolchain. Swift's `swiftc` path, engine `.swiftmodule` include paths and
//! Clang module maps become the cargo executable, the engine script crates and
//! the same include strings the analysis workspace passes to rust-analyzer.
//! Without an async runtime `validate` is synchronous.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use diffuse_script::dynamic_script::script_compiler::ScriptCompiler;

use super::resolution::{SwiftToolchain, SwiftToolchainError};
use crate::application::plugins::language_service::PluginLanguageService;
use crate::scripting::script_language_support::{
    ConnectTransport, MemoryUsage, ScriptLanguageSupport,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptAnalysisConfiguration {
    pub scripts_directory: PathBuf,
    pub build_directory: PathBuf,
    pub engine_module_paths: Vec<String>,
    pub clang_module_map_paths: Vec<String>,
    pub clang_include_paths: Vec<String>,
}

impl ScriptAnalysisConfiguration {
    pub fn new(
        scripts_directory: PathBuf,
        build_directory: PathBuf,
        engine_module_paths: Vec<String>,
        clang_module_map_paths: Vec<String>,
        clang_include_paths: Vec<String>,
    ) -> Self {
        Self {
            scripts_directory,
            build_directory,
            engine_module_paths,
            clang_module_map_paths,
            clang_include_paths,
        }
    }
    /// Swift selected `swiftc` from the toolchain (or a fallback) plus module
    /// search paths. D1 selects the cargo that builds the scripts; cargo
    /// resolves the engine crates from the `Scripts/` manifest, so the include
    /// paths only reach the analysis server through [`Self::support`].
    pub fn compiler(&self, toolchain: Option<&SwiftToolchain>, fallback: &str) -> ScriptCompiler {
        let cargo_path = toolchain
            .and_then(|toolchain| toolchain.environment.get("CARGO").cloned())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| cargo_from_fallback(fallback));
        let environment = toolchain
            .map(|toolchain| toolchain.environment.clone())
            .unwrap_or_else(|| std::env::vars().collect());
        let mut compiler = ScriptCompiler::new(&self.build_directory);
        compiler.cargo_path = cargo_path;
        compiler.environment = environment;
        compiler
    }

    pub fn support(
        &self,
        toolchain: &SwiftToolchain,
        plugin: &PluginLanguageService,
    ) -> ScriptLanguageSupport {
        let connect_plugin: PluginLanguageService = (*plugin).clone();
        let memory_plugin: PluginLanguageService = (*plugin).clone();
        ScriptLanguageSupport::new(
            self.scripts_directory.clone(),
            self.engine_module_paths.clone(),
            self.clang_module_map_paths.clone(),
            self.clang_include_paths.clone(),
            toolchain.language_server_url.clone(),
            toolchain.environment.clone(),
            Some(
                Arc::new(move |command: &cove_system::command::ProcessCommand| {
                    connect_plugin
                        .connect(command)
                        .map_err(|error| error.to_string())
                }) as ConnectTransport,
            ),
            Some(Arc::new(move || memory_plugin.resident_memory_bytes()) as MemoryUsage),
        )
    }

    pub fn validate(&self, toolchain: &SwiftToolchain) -> Result<(), SwiftToolchainError> {
        toolchain.validate_analysis(
            &self.engine_module_paths,
            &self.clang_module_map_paths,
            &self.clang_include_paths,
        )
    }
}

/// The toolchain, its language support and the last failure. Swift's final
/// class is shared across the editor's threads, so the state sits behind a
/// `Mutex`.
#[derive(Clone)]
pub struct ScriptToolchainState {
    pub toolchain: Option<SwiftToolchain>,
    pub support: Option<Arc<ScriptLanguageSupport>>,
    pub failure: Option<String>,
}

pub struct ScriptToolchainSession {
    value: Mutex<ScriptToolchainState>,
}

impl ScriptToolchainSession {
    pub fn new(state: ScriptToolchainState) -> Self {
        Self {
            value: Mutex::new(state),
        }
    }

    pub fn state(&self) -> ScriptToolchainState {
        self.lock().clone()
    }

    pub fn replace(&self, state: ScriptToolchainState) {
        *self.lock() = state;
    }

    fn lock(&self) -> MutexGuard<'_, ScriptToolchainState> {
        self.value.lock().unwrap_or_else(|error| error.into_inner())
    }
}

/// The host resolves a `rustc` override before a toolchain exists; the cargo
/// that builds the same scripts sits beside it. Any other override is taken as
/// the cargo executable itself.
fn cargo_from_fallback(fallback: &str) -> String {
    let path = std::path::Path::new(fallback);
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let is_rustc = name == "rustc" || name == "rustc.exe";
    if is_rustc {
        let cargo_name = if cfg!(windows) { "cargo.exe" } else { "cargo" };
        return path
            .parent()
            .map(|directory| directory.join(cargo_name))
            .unwrap_or_else(|| PathBuf::from(cargo_name))
            .to_string_lossy()
            .into_owned();
    }
    fallback.to_string()
}
