//! `Editor/Sources/EditorCore/Scripting/Dynamic/DynamicScriptManager.swift`.
//!
//! Manages dynamically compiled project scripts.
//!
//! Responsibilities:
//! - Scan `Scripts/*.rs` files in the project directory
//! - Read / write / create script sources
//! - Compile scripts through [`DynamicScriptBuildCoordinator`] (off the caller's thread)
//! - Register scripts with the [`ScriptRuntime`] (hot-reload via generation bump)
//! - Track compilation status and diagnostics
//!
//! D1 rewrite: gameplay code is Rust, so the scan looks for `.rs`, the compiler
//! is `rustc`/cargo and the analysis server is rust-analyzer. The `Swift*`
//! names are kept because the persisted toolchain preferences and the whole
//! pipeline use them; behaviour is Rust's.
//!
//! Swift's `@MainActor` status dictionary and its `Task {}` fan-out have no
//! async runtime here: the status map lives behind a `Mutex`, every `Task {}`
//! becomes a named thread that invokes its completion where it finishes, and
//! the manager is shared as an `Arc` — the Rust form of Swift's shared class
//! reference.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::paths::PathIdentity;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_script::ScriptRuntime;
use diffuse_script::dynamic_script::script_loader::ScriptLoader;

use crate::application::plugins::language_service::PluginLanguageService;
use crate::scripting::assets::script_asset_registry::{
    ScriptAssetID, ScriptAssetRegistry, ScriptAssetRegistryError,
};
use crate::scripting::dynamic::dynamic_script_build_coordinator::{
    DynamicScriptBuildCoordinator, DynamicScriptBuildOutcome, SwiftScriptCompilerDriver,
};
use crate::scripting::dynamic::script_project_trust::{
    ScriptProjectTrustError, ScriptProjectTrustState, ScriptProjectTrustStore,
};
use crate::scripting::rust_analyzer::language::assistance::{
    ScriptDocumentSymbol, ScriptSignatureHelp, ScriptWorkspaceSymbol,
};
use crate::scripting::rust_analyzer::language::details::ScriptLanguageServiceDetails;
use crate::scripting::rust_analyzer::language::editing::{
    ScriptCodeAction, ScriptLanguageEditError, ScriptRenamePreparation, ScriptWorkspaceEdit,
};
use crate::scripting::rust_analyzer::language::script_language_lifecycle::StateHandler;
use crate::scripting::rust_analyzer::language::script_language_models::{
    ScriptCompletionItem, ScriptCompletionResult, ScriptDefinitionLocation, ScriptHoverResult,
    ScriptLanguageSupportError,
};
use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptLanguageSpan,
};
use crate::scripting::script_language_support::{
    DetailsHandler, DiagnosticsHandler, ScriptLanguageSupport, ScriptLanguageSupportFailure,
};
use crate::scripting::toolchain::activation::ScriptToolchainActivation;
use crate::scripting::toolchain::analysis_session::{
    ScriptAnalysisConfiguration, ScriptToolchainSession, ScriptToolchainState,
};
use crate::scripting::toolchain::preferences::SwiftToolchainPreferences;
use crate::scripting::toolchain::resolution::{
    SwiftToolchain, SwiftToolchainError, SwiftToolchainResolver,
};

/// `(@escaping @Sendable (CompilationStatus) -> Void)`.
pub type CompilationStatusHandler = Arc<dyn Fn(CompilationStatus) + Send + Sync>;
/// `(@escaping @Sendable (ScriptFile, CompilationStatus) -> Void)`.
pub type ScriptCompilationHandler = Arc<dyn Fn(&ScriptFile, CompilationStatus) + Send + Sync>;
/// `(@escaping @Sendable () -> Void)`.
pub type CompilationCompletionHandler = Arc<dyn Fn() + Send + Sync>;

/// A script source file in the project's `Scripts/` directory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptFile {
    pub url: PathBuf,
    pub asset_id: ScriptAssetID,
    /// Stable UUID-backed identifier used to register the script with the runtime.
    pub identifier: String,
    /// Pre-registry identifiers retained as runtime aliases so existing
    /// scenes continue to resolve after the identity migration or a rename.
    pub legacy_identifiers: Vec<String>,
    /// Display name derived from the file name, e.g. `PlayerMovement`.
    pub display_name: String,
}

impl ScriptFile {
    pub fn new(url: PathBuf) -> Self {
        Self::with_asset_id(url, ScriptAssetID::new(), Vec::new())
    }

    pub(crate) fn with_asset_id(
        url: PathBuf,
        asset_id: ScriptAssetID,
        legacy_identifiers: Vec<String>,
    ) -> Self {
        let display_name = url
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_default();
        let identifier = asset_id.runtime_identifier();
        ScriptFile {
            url,
            asset_id,
            identifier,
            legacy_identifiers,
            display_name,
        }
    }
}

/// A script file paired with the text the editor currently holds — which may
/// be newer than what is on disk (unsaved edits).
///
/// Swift defines this in `ScriptLanguageModels.swift`; it is sibling to
/// [`ScriptFile`], so the Rust port keeps it in the same file until the
/// language-model module re-exports it.
#[derive(Clone, Debug)]
pub struct ScriptLanguageSource {
    pub file: ScriptFile,
    pub text: TextBuffer,
    pub revision: u64,
    /// A project file analyzed in place rather than mirrored into the script package.
    pub is_project_source: bool,
}

impl ScriptLanguageSource {
    pub fn new(file: ScriptFile, text: TextBuffer) -> Self {
        ScriptLanguageSource {
            file,
            text,
            revision: 0,
            is_project_source: false,
        }
    }
}

/// Outcome of the most recent compilation attempt for a script.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CompilationStatus {
    Idle,
    Compiling,
    Succeeded,
    Cancelled,
    Blocked { message: String },
    Failed { message: String },
}

impl CompilationStatus {
    pub fn is_failed(&self) -> bool {
        matches!(self, CompilationStatus::Failed { .. })
    }

    pub fn is_blocked(&self) -> bool {
        matches!(self, CompilationStatus::Blocked { .. })
    }

    pub fn message(&self) -> Option<&str> {
        match self {
            CompilationStatus::Failed { message } | CompilationStatus::Blocked { message } => {
                Some(message)
            }
            CompilationStatus::Idle
            | CompilationStatus::Compiling
            | CompilationStatus::Succeeded
            | CompilationStatus::Cancelled => None,
        }
    }
}

/// Swift's `final class DynamicScriptManager: @unchecked Sendable`.
///
/// Every stored property that Swift mutated from `@MainActor` or from a `Task`
/// is behind a lock here, so `&self` methods stay shareable across the build
/// threads.
pub struct DynamicScriptManager {
    project_directory: String,
    asset_registry: ScriptAssetRegistry,
    trust_store: ScriptProjectTrustStore,
    build_coordinator: Arc<DynamicScriptBuildCoordinator>,
    analysis_configuration: ScriptAnalysisConfiguration,
    toolchain_session: ScriptToolchainSession,
    pub(crate) language_plugin: PluginLanguageService,
    status_by_script_id: Mutex<BTreeMap<String, CompilationStatus>>,
}

impl DynamicScriptManager {
    /// Host/operator configuration only; project files cannot select an executable.
    pub const COMPILER_OVERRIDE_ENVIRONMENT_KEY: &'static str = "COVE_RUSTC_PATH";

    /// Swift's `init(projectDirectory:scriptRuntime:engineModulePaths:)` with its
    /// `clangModuleMapPaths: []`, `clangIncludePaths: []`,
    /// `scriptTrustStorageURL: nil` and `swiftCompilerPath: nil` defaults.
    ///
    /// - `project_directory`: Absolute path to the project root. Scripts live
    ///   in `<project_directory>/Scripts/`.
    /// - `script_runtime`: The runtime that scripts will be registered with.
    /// - `engine_module_paths`: Directories containing the engine's script
    ///   crates so scripts can `use diffuse_scene::…`, `use diffuse_math::…`,
    ///   etc.
    pub fn new(
        project_directory: &str,
        script_runtime: ScriptRuntime,
        engine_module_paths: Vec<String>,
    ) -> Self {
        Self::with_options(
            project_directory,
            script_runtime,
            engine_module_paths,
            Vec::new(),
            Vec::new(),
            None,
            None,
        )
    }

    /// Every parameter of Swift's designated `init`.
    pub fn with_options(
        project_directory: &str,
        script_runtime: ScriptRuntime,
        engine_module_paths: Vec<String>,
        clang_module_map_paths: Vec<String>,
        clang_include_paths: Vec<String>,
        script_trust_storage_url: Option<PathBuf>,
        swift_compiler_path: Option<String>,
    ) -> Self {
        let language_plugin = PluginLanguageService::new();
        let asset_registry = ScriptAssetRegistry::new(project_directory);
        let trust_store = match script_trust_storage_url {
            Some(storage_url) => ScriptProjectTrustStore::with_storage_url(storage_url),
            // Swift's `init(storageURL: nil)` falls back to the application
            // support default the store resolves from the environment.
            None => ScriptProjectTrustStore::new(),
        };
        let configuration = ScriptAnalysisConfiguration::new(
            Self::scripts_directory(project_directory),
            Self::scripts_build_directory(project_directory),
            engine_module_paths.clone(),
            clang_module_map_paths,
            clang_include_paths,
        );
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        let resolution = SwiftToolchainResolver::resolve(
            swift_compiler_path.as_deref(),
            &environment,
            &SwiftToolchainPreferences::load_with_default(),
        );
        let compiler = configuration.compiler(
            resolution.as_ref().ok(),
            &Self::resolved_compiler_path(swift_compiler_path.as_deref(), &environment),
        );
        let build_coordinator = Arc::new(DynamicScriptBuildCoordinator::new(
            Arc::new(SwiftScriptCompilerDriver::new(compiler)),
            Arc::new(ScriptLoader::new()),
            script_runtime,
        ));

        let toolchain_session = match resolution {
            Ok(toolchain) => {
                let support = if engine_module_paths.is_empty() {
                    None
                } else {
                    Some(Arc::new(
                        configuration.support(&toolchain, &language_plugin),
                    ))
                };
                let failure = if engine_module_paths.is_empty() {
                    Some(
                        "Could not locate the built engine script crates for script analysis."
                            .to_string(),
                    )
                } else {
                    None
                };
                ScriptToolchainSession::new(ScriptToolchainState {
                    toolchain: Some(toolchain),
                    support,
                    failure,
                })
            }
            Err(error) => ScriptToolchainSession::new(ScriptToolchainState {
                toolchain: None,
                support: None,
                failure: Some(error.to_string()),
            }),
        };

        DynamicScriptManager {
            project_directory: project_directory.to_string(),
            asset_registry,
            trust_store,
            build_coordinator,
            analysis_configuration: configuration,
            toolchain_session,
            language_plugin,
            status_by_script_id: Mutex::new(BTreeMap::new()),
        }
    }

    pub(crate) fn resolved_compiler_path(
        compiler_override: Option<&str>,
        environment: &BTreeMap<String, String>,
    ) -> String {
        if let Some(override_value) = compiler_override
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return override_value.to_string();
        }
        if let Some(configured) = environment
            .get(Self::COMPILER_OVERRIDE_ENVIRONMENT_KEY)
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
        {
            return configured.to_string();
        }
        "rustc".to_string()
    }

    /// Swift's `environment: ProcessInfo.processInfo.environment` default.
    pub fn resolved_compiler_path_with_default(compiler_override: Option<&str>) -> String {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::resolved_compiler_path(compiler_override, &environment)
    }

    // Directory layout

    /// `<projectDirectory>/Scripts/`
    pub fn scripts_directory_url(&self) -> PathBuf {
        Self::scripts_directory(&self.project_directory)
    }

    fn scripts_directory(project_directory: &str) -> PathBuf {
        Path::new(project_directory).join("Scripts")
    }

    /// `<projectDirectory>/Scripts/.build/` — compiled libraries go here.
    pub fn scripts_build_directory(project_directory: &str) -> PathBuf {
        Path::new(project_directory).join("Scripts").join(".build")
    }

    pub fn legacy_identifier_for_file_stem(stem: &str) -> String {
        format!("scripts.{}", stem.to_lowercase().replace(' ', "-"))
    }

    // File operations

    /// Returns all `.rs` files in the project's `Scripts/` directory, sorted by
    /// name.
    pub fn scan_script_files(&self) -> Result<Vec<ScriptFile>, DynamicScriptManagerError> {
        let directory = self.scripts_directory_url();
        if !directory.exists() {
            return Ok(Vec::new());
        }
        let mut contents: Vec<PathBuf> = Vec::new();
        for entry in std::fs::read_dir(&directory)? {
            let url = entry?.path();
            if url
                .extension()
                .is_some_and(|extension| extension.to_string_lossy().eq_ignore_ascii_case("rs"))
            {
                contents.push(url);
            }
        }
        let files: Vec<ScriptFile> = self
            .asset_registry
            .resolve(contents)?
            .into_iter()
            .map(|asset| ScriptFile::with_asset_id(asset.url, asset.id, asset.legacy_identifiers))
            .collect();
        let mut alias_counts: BTreeMap<String, usize> = BTreeMap::new();
        for file in &files {
            for legacy_identifier in &file.legacy_identifiers {
                *alias_counts.entry(legacy_identifier.clone()).or_default() += 1;
            }
        }
        let mut scanned: Vec<ScriptFile> = files
            .into_iter()
            .map(|file| {
                let legacy_identifiers = file
                    .legacy_identifiers
                    .into_iter()
                    .filter(|legacy_identifier| {
                        alias_counts.get(legacy_identifier).copied() == Some(1)
                    })
                    .collect();
                ScriptFile::with_asset_id(file.url, file.asset_id, legacy_identifiers)
            })
            .collect();
        // `localizedCaseInsensitiveCompare(_:) == .orderedAscending`
        scanned.sort_by(|left, right| {
            left.display_name
                .to_lowercase()
                .cmp(&right.display_name.to_lowercase())
        });
        Ok(scanned)
    }

    pub fn script_file_at(
        &self,
        url: &Path,
    ) -> Result<Option<ScriptFile>, DynamicScriptManagerError> {
        Ok(self
            .scan_script_files()?
            .into_iter()
            .find(|file| PathIdentity::same_location(&file.url, url)))
    }

    /// Swift's `start(sources:onDiagnostics:onStateChange:onDetailsChange:)`
    /// with its `nil` handler defaults.
    pub fn start_language_service(
        &self,
        sources: &[ScriptLanguageSource],
        on_diagnostics: DiagnosticsHandler,
        on_state_change: Option<StateHandler>,
        on_details_change: Option<DetailsHandler>,
    ) -> Result<(), DynamicScriptManagerError> {
        let Some(language_support) = self.language_support() else {
            return Err(self.unavailable_language_support());
        };
        if let Some(toolchain) = self.swift_toolchain() {
            self.analysis_configuration.validate(&toolchain)?;
        }
        language_support.start(sources, on_diagnostics, on_state_change, on_details_change)?;
        Ok(())
    }

    /// Swift's `onStateChange: nil, onDetailsChange: nil` defaults.
    pub fn start_language_service_with_defaults(
        &self,
        sources: &[ScriptLanguageSource],
        on_diagnostics: DiagnosticsHandler,
    ) -> Result<(), DynamicScriptManagerError> {
        self.start_language_service(sources, on_diagnostics, None, None)
    }

    pub fn update_language_source(
        &self,
        script_id: &str,
        text: &TextBuffer,
        revision: u64,
    ) -> Result<(), DynamicScriptManagerError> {
        let Some(language_support) = self.language_support() else {
            return Err(self.unavailable_language_support());
        };
        language_support.update(script_id, text.clone(), revision);
        Ok(())
    }

    pub fn open_project_source(
        &self,
        source: &ScriptLanguageSource,
    ) -> Result<(), DynamicScriptManagerError> {
        if let Some(language_support) = self.language_support() {
            language_support.open_project_source(source)?;
        }
        Ok(())
    }

    pub fn did_save_language_source(&self, script_id: &str) {
        if let Some(language_support) = self.language_support() {
            language_support.did_save(script_id);
        }
    }

    pub fn close_project_source(&self, script_id: &str) {
        if let Some(language_support) = self.language_support() {
            language_support.close_project_source(script_id);
        }
    }

    pub fn refresh_language_workspace(
        &self,
        sources: &[ScriptLanguageSource],
    ) -> Result<(), DynamicScriptManagerError> {
        let Some(language_support) = self.language_support() else {
            return Err(self.unavailable_language_support());
        };
        language_support.restart(sources)?;
        Ok(())
    }

    pub fn stop_language_service(&self) {
        if let Some(language_support) = self.language_support() {
            language_support.stop();
        }
    }

    /// Swift's `preferencesDirectory: SwiftToolchainPreferences.directory` default.
    pub(crate) fn configure_swift_toolchain_with_default(
        &self,
        path: Option<&str>,
        activation: &ScriptToolchainActivation,
    ) -> Result<(), DynamicScriptManagerError> {
        self.configure_swift_toolchain(path, &SwiftToolchainPreferences::directory(), activation)
    }

    pub(crate) fn configure_swift_toolchain(
        &self,
        path: Option<&str>,
        preferences_directory: &Path,
        activation: &ScriptToolchainActivation,
    ) -> Result<(), DynamicScriptManagerError> {
        let previous_preferences = SwiftToolchainPreferences::load(preferences_directory);
        let mut preferences = previous_preferences.clone();
        preferences.selected_path = path.map(|value| value.trim().to_string());
        if preferences.selected_path.as_deref() == Some("") {
            preferences.selected_path = None;
        }
        let configuration = &self.analysis_configuration;
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        // Swift ran the probe in `Task.detached`; the blocking port runs it
        // inline because the caller already owns a worker thread.
        let toolchain = SwiftToolchainResolver::resolve(None, &environment, &preferences)?;
        configuration.validate(&toolchain)?;
        let previous_state = self.toolchain_session.state();
        let compiler =
            configuration.compiler(Some(&toolchain), &toolchain.compiler_url.to_string_lossy());
        let previous_compiler = self
            .build_coordinator
            .begin_compiler_change(Arc::new(SwiftScriptCompilerDriver::new(compiler)))?;

        let mut did_replace_state = false;
        let outcome: Result<(), DynamicScriptManagerError> = (|| {
            (activation.suspend)();
            preferences.save(preferences_directory)?;
            self.toolchain_session.replace(ScriptToolchainState {
                toolchain: Some(toolchain.clone()),
                support: Some(Arc::new(
                    configuration.support(&toolchain, &self.language_plugin),
                )),
                failure: None,
            });
            did_replace_state = true;
            (activation.activate)()?;
            Ok(())
        })();

        if let Err(failure) = outcome {
            let mut recovery_failures: Vec<String> = Vec::new();
            if did_replace_state {
                if let Some(language_support) = self.language_support() {
                    language_support.stop();
                }
                self.toolchain_session.replace(previous_state);
                if let Err(error) = previous_preferences.save(preferences_directory) {
                    recovery_failures.push(error.to_string());
                }
                if let Err(error) = (activation.recover)() {
                    recovery_failures.push(error.to_string());
                }
            }
            self.build_coordinator
                .finish_compiler_change(Some(previous_compiler));
            if !recovery_failures.is_empty() {
                return Err(SwiftToolchainError::Unavailable(format!(
                    "{failure}\nCould not fully restore the previous Rust configuration: {}",
                    recovery_failures.join("\n")
                ))
                .into());
            }
            return Err(failure);
        }

        self.build_coordinator.finish_compiler_change(None);
        Ok(())
    }

    // Native-code trust boundary

    pub fn project_trust_state(&self) -> ScriptProjectTrustState {
        self.trust_store.state(&self.project_directory)
    }

    pub fn trust_store_warning(&self) -> Option<&str> {
        self.trust_store.load_warning()
    }

    pub fn set_project_trusted(&self, trusted: bool) -> Result<(), DynamicScriptManagerError> {
        self.trust_store
            .set_trusted(trusted, &self.project_directory)?;
        if trusted {
            return Ok(());
        }
        for file in self.scan_script_files().unwrap_or_default() {
            self.unload(&file.identifier);
        }
        Ok(())
    }

    // Semantic queries

    pub fn hover(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Option<ScriptHoverResult>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.hover(script_id, at)?)
        })
    }

    pub fn completion(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
        trigger_character: Option<&str>,
    ) -> Result<ScriptCompletionResult, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.completion(script_id, at, trigger_character)?)
        })
    }

    /// Swift's `triggerCharacter: String? = nil` default.
    pub fn completion_with_defaults(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<ScriptCompletionResult, DynamicScriptManagerError> {
        self.completion(script_id, at, None)
    }

    pub fn workspace_tests(&self) -> Result<Vec<String>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| Ok(language_support.workspace_tests()?))
    }

    pub fn workspace_symbols(
        &self,
        query: &str,
    ) -> Result<Vec<ScriptWorkspaceSymbol>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.workspace_symbols(query)?)
        })
    }

    pub fn resolve_completion(
        &self,
        item: &ScriptCompletionItem,
    ) -> Result<ScriptCompletionItem, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.resolve_completion(item.clone())?)
        })
    }

    pub fn definition(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.definition(script_id, at)?)
        })
    }

    pub fn references(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.references(script_id, at)?)
        })
    }

    pub fn implementations(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.implementations(script_id, at)?)
        })
    }

    pub fn supertypes(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.supertypes(script_id, at)?)
        })
    }

    pub fn subtypes(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.subtypes(script_id, at)?)
        })
    }

    pub fn prepare_rename(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Option<ScriptRenamePreparation>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.prepare_rename(script_id, at)?)
        })
    }

    pub fn rename(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
        new_name: &str,
    ) -> Result<ScriptWorkspaceEdit, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.rename(script_id, at, new_name)?)
        })
    }

    pub fn code_actions(
        &self,
        script_id: &str,
        range: ScriptLanguageSpan,
    ) -> Result<Vec<ScriptCodeAction>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.code_actions(script_id, range)?)
        })
    }

    pub fn resolve_code_action(
        &self,
        action: &ScriptCodeAction,
    ) -> Result<ScriptCodeAction, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.resolve_code_action(action.clone())?)
        })
    }

    pub fn signature_help(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Option<ScriptSignatureHelp>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.signature_help(script_id, at)?)
        })
    }

    pub fn document_symbols(
        &self,
        script_id: &str,
    ) -> Result<Vec<ScriptDocumentSymbol>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.document_symbols(script_id)?)
        })
    }

    pub fn formatting(
        &self,
        script_id: &str,
        range: Option<ScriptLanguageSpan>,
        tab_size: usize,
        insert_spaces: bool,
    ) -> Result<ScriptWorkspaceEdit, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.formatting(script_id, range, tab_size, insert_spaces)?)
        })
    }

    /// Swift's `range: nil, tabSize: 4, insertSpaces: true` defaults.
    pub fn formatting_with_defaults(
        &self,
        script_id: &str,
    ) -> Result<ScriptWorkspaceEdit, DynamicScriptManagerError> {
        self.formatting(script_id, None, 4, true)
    }

    pub fn document_highlights(
        &self,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptLanguageSpan>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.document_highlights(script_id, at)?)
        })
    }

    pub fn language_service_details(&self) -> Option<ScriptLanguageServiceDetails> {
        self.language_support()
            .map(|language_support| language_support.language_service_details())
    }

    pub fn reference_document(
        &self,
        document_uri: &str,
    ) -> Result<Option<String>, DynamicScriptManagerError> {
        self.perform_on_language_service(|language_support| {
            Ok(language_support.reference_document(document_uri)?)
        })
    }

    fn perform_on_language_service<T>(
        &self,
        body: impl FnOnce(&Arc<ScriptLanguageSupport>) -> Result<T, DynamicScriptManagerError>,
    ) -> Result<T, DynamicScriptManagerError> {
        let Some(language_support) = self.language_support() else {
            return Err(self.unavailable_language_support());
        };
        body(&language_support)
    }

    fn unavailable_language_support(&self) -> DynamicScriptManagerError {
        ScriptLanguageSupportError::Unavailable(
            self.language_support_unavailable_message()
                .unwrap_or_else(|| "Unknown setup error.".to_string()),
        )
        .into()
    }

    /// Reads the UTF-8 source of a script file.
    pub fn read_source(&self, url: &Path) -> Result<String, DynamicScriptManagerError> {
        Ok(std::fs::read_to_string(url)?)
    }

    /// Writes source back to disk. The caller is responsible for calling
    /// [`DynamicScriptManager::compile_and_load`] afterwards if a hot-reload is
    /// desired.
    pub fn write_source(&self, source: &str, url: &Path) -> Result<(), DynamicScriptManagerError> {
        AtomicFile::write(source.as_bytes(), url, Access::Inherit)?;
        Ok(())
    }

    /// Creates a new script file with the given name (without extension) and
    /// initial source. Returns the file URL.
    pub fn create_script(
        &self,
        name: &str,
        source: &str,
    ) -> Result<PathBuf, DynamicScriptManagerError> {
        let directory = self.scripts_directory_url();
        std::fs::create_dir_all(&directory)?;
        let normalized_name = name.trim();
        if normalized_name.is_empty()
            || normalized_name == "."
            || normalized_name == ".."
            || normalized_name
                .chars()
                .any(|character| matches!(character, '/' | '\\' | ':'))
        {
            return Err(ScriptFileError::InvalidName(name.to_string()).into());
        }

        let url = directory.join(format!("{normalized_name}.rs"));
        if url.exists() {
            return Err(ScriptFileError::AlreadyExists(normalized_name.to_string()).into());
        }
        // `FileManager.createFile(atPath:contents:)` reserves the name before the
        // atomic write replaces it; a second creator loses here.
        if std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&url)
            .is_err()
        {
            return Err(ScriptFileError::AlreadyExists(normalized_name.to_string()).into());
        }
        if let Err(error) = AtomicFile::write(source.as_bytes(), &url, Access::Inherit) {
            let _ = std::fs::remove_file(&url);
            return Err(error.into());
        }
        Ok(url)
    }

    /// Deletes a script file and unregisters it from the runtime.
    pub fn delete_script(&self, file: &ScriptFile) -> Result<(), DynamicScriptManagerError> {
        self.unload(&file.identifier);
        std::fs::remove_file(&file.url)?;
        self.asset_registry.remove(&file.asset_id)?;
        Ok(())
    }

    // Compile & load

    /// Compiles a script, loads the resulting library, and registers it with
    /// the runtime. Runs on a background thread; completion is delivered on
    /// that thread.
    ///
    /// Registering an existing identifier bumps the runtime's generation,
    /// which tears down and re-creates all active instances — this is the
    /// hot-reload path.
    pub fn compile_and_load(
        self: &Arc<Self>,
        script_id: &str,
        source_url: &Path,
        completion: CompilationStatusHandler,
    ) {
        if !self.project_trust_state().allows_execution() {
            let status = CompilationStatus::Blocked {
                message: ScriptProjectTrustError::ExecutionBlocked.to_string(),
            };
            self.update_status(script_id, &status);
            completion(status);
            return;
        }
        self.update_status(script_id, &CompilationStatus::Compiling);

        let coordinator = Arc::clone(&self.build_coordinator);
        let weak_manager = Arc::downgrade(self);
        let script_id = script_id.to_string();
        let source_url = source_url.to_path_buf();
        std::thread::Builder::new()
            .name("dynamic-script-build".to_string())
            .spawn(move || {
                let aliases: Vec<String> = match weak_manager
                    .upgrade()
                    .map(|manager| manager.scan_script_files())
                {
                    Some(Ok(files)) => files
                        .into_iter()
                        .find(|file| file.identifier == script_id)
                        .map(|file| file.legacy_identifiers)
                        .unwrap_or_default(),
                    Some(Err(error)) => {
                        let status = CompilationStatus::Failed {
                            message: error.to_string(),
                        };
                        if let Some(manager) = weak_manager.upgrade() {
                            manager.update_status(&script_id, &status);
                        }
                        completion(status);
                        return;
                    }
                    // `self?.scanScriptFiles()` yields an empty list once the
                    // manager is gone.
                    None => Vec::new(),
                };
                let outcome = coordinator.build(&script_id, &aliases, &source_url);
                let status = match outcome {
                    DynamicScriptBuildOutcome::Succeeded { .. } => CompilationStatus::Succeeded,
                    DynamicScriptBuildOutcome::Cancelled => CompilationStatus::Cancelled,
                    DynamicScriptBuildOutcome::Failed { message } => {
                        CompilationStatus::Failed { message }
                    }
                    DynamicScriptBuildOutcome::Superseded => return,
                };
                if let Some(manager) = weak_manager.upgrade() {
                    manager.update_status(&script_id, &status);
                }
                completion(status);
            })
            .expect("dynamic script build thread");
    }

    pub fn cancel_build(&self, script_id: &str) {
        let coordinator = Arc::clone(&self.build_coordinator);
        let script_id = script_id.to_string();
        std::thread::Builder::new()
            .name("dynamic-script-cancel".to_string())
            .spawn(move || coordinator.cancel(&script_id))
            .expect("dynamic script cancel thread");
    }

    fn update_status(&self, script_id: &str, status: &CompilationStatus) {
        self.lock_status()
            .insert(script_id.to_string(), status.clone());
    }

    /// Compiles project scripts one at a time so the shared dynamic loader is
    /// never mutated concurrently.
    pub fn compile_all_scripts(
        self: &Arc<Self>,
        on_script_completion: ScriptCompilationHandler,
        completion: CompilationCompletionHandler,
    ) -> Result<(), DynamicScriptManagerError> {
        self.compile_next(
            Arc::new(self.scan_script_files()?),
            0,
            on_script_completion,
            completion,
        );
        Ok(())
    }

    fn compile_next(
        self: &Arc<Self>,
        files: Arc<Vec<ScriptFile>>,
        index: usize,
        on_script_completion: ScriptCompilationHandler,
        completion: CompilationCompletionHandler,
    ) {
        let Some(file) = files.get(index).cloned() else {
            completion();
            return;
        };
        let script_id = file.identifier.clone();
        let source_url = file.url.clone();
        let manager = Arc::clone(self);
        let next_files = Arc::clone(&files);
        let next_on_script_completion = Arc::clone(&on_script_completion);
        let next_completion = Arc::clone(&completion);
        let handler: CompilationStatusHandler = Arc::new(move |status| {
            next_on_script_completion(&file, status);
            manager.compile_next(
                Arc::clone(&next_files),
                index + 1,
                Arc::clone(&next_on_script_completion),
                Arc::clone(&next_completion),
            );
        });
        self.compile_and_load(&script_id, &source_url, handler);
    }

    /// Unregisters a script and retires its mapped artifact once active runtime
    /// instances release their generation lease.
    pub fn unload(&self, script_id: &str) {
        let coordinator = Arc::clone(&self.build_coordinator);
        let identifier = script_id.to_string();
        std::thread::Builder::new()
            .name("dynamic-script-unload".to_string())
            .spawn(move || coordinator.unload(&identifier))
            .expect("dynamic script unload thread");
        self.update_status(script_id, &CompilationStatus::Idle);
    }

    // Status tracking

    /// Returns the compilation status for a script identifier.
    pub fn status(&self, script_id: &str) -> CompilationStatus {
        self.lock_status()
            .get(script_id)
            .cloned()
            .unwrap_or(CompilationStatus::Idle)
    }

    fn language_support(&self) -> Option<Arc<ScriptLanguageSupport>> {
        self.toolchain_session.state().support
    }

    fn language_support_unavailable_message(&self) -> Option<String> {
        self.toolchain_session.state().failure
    }

    pub fn swift_toolchain(&self) -> Option<SwiftToolchain> {
        self.toolchain_session.state().toolchain
    }

    fn lock_status(&self) -> MutexGuard<'_, BTreeMap<String, CompilationStatus>> {
        self.status_by_script_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptFileError {
    #[error("Invalid script name '{0}'. Use a file name without path separators.")]
    InvalidName(String),
    #[error("A script named '{0}' already exists.")]
    AlreadyExists(String),
}

impl ScriptFileError {
    /// Swift's `LocalizedError.errorDescription`.
    pub fn error_description(&self) -> String {
        self.to_string()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DynamicScriptManagerError {
    #[error(transparent)]
    ScriptFile(#[from] ScriptFileError),
    #[error(transparent)]
    Registry(#[from] ScriptAssetRegistryError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Toolchain(#[from] SwiftToolchainError),
    #[error(transparent)]
    LanguageSupport(#[from] ScriptLanguageSupportError),
    #[error(transparent)]
    LanguageSupportFailure(#[from] ScriptLanguageSupportFailure),
    #[error(transparent)]
    LanguageEdit(#[from] ScriptLanguageEditError),
}
