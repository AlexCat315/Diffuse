//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/AnalysisCache.swift`.
//!
//! D1 rewrite: the scratch directory belongs to `rust-analyzer`'s cargo
//! analysis instead of SourceKit-LSP's SwiftPM package. The cache identity
//! therefore tracks the `rust-analyzer` executable, `rustc`, the Rust sysroot,
//! the engine script crates and the include flags; rebuilding any of them
//! discards the generated cargo target cache, exactly like Swift discarded the
//! cache when its toolchain, SDK or `.swiftmodule` files changed.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::{Access, resolve_path};
use diffuse_capability::support::swift_date::{SWIFT_DATE_REFERENCE_UNIX_SECONDS, SwiftDate};
use serde::{Deserialize, Serialize};

use crate::scripting::rust_analyzer::language::script_language_models::ScriptLanguageSupportError;
use crate::scripting::rust_analyzer::language::script_language_workspace::ScriptLanguageWorkspace;

/// One file in the analysis environment whose modification must invalidate the
/// scratch cache.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScriptAnalysisCacheFile {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<SwiftDate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
}

impl ScriptAnalysisCacheFile {
    pub fn new(url: &Path) -> Self {
        let path = resolve_path(url).unwrap_or_else(|_| url.to_path_buf());
        let metadata = std::fs::metadata(&path).ok();
        Self {
            path: path.to_string_lossy().into_owned(),
            modified: metadata
                .as_ref()
                .and_then(|attributes| attributes.modified().ok())
                .map(swift_date),
            size: metadata.as_ref().map(|attributes| attributes.len()),
        }
    }

    pub fn module_files(url: &Path) -> Vec<Self> {
        let mut children: Vec<PathBuf> = std::fs::read_dir(url)
            .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
            .unwrap_or_default();
        children.sort_by(|left, right| left.to_string_lossy().cmp(&right.to_string_lossy()));
        let mut files = Vec::with_capacity(children.len() + 1);
        files.push(Self::new(url));
        files.extend(children.iter().map(|child| Self::new(child)));
        files
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScriptAnalysisCacheIdentity {
    pub workspace: String,
    pub executable: ScriptAnalysisCacheFile,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compiler: Option<ScriptAnalysisCacheFile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sysroot: Option<ScriptAnalysisCacheFile>,
    pub modules: Vec<ScriptAnalysisCacheFile>,
    pub flags: Vec<String>,
}

impl ScriptLanguageWorkspace {
    pub fn prepare_scratch(
        &self,
        executable_url: &Path,
        environment: &BTreeMap<String, String>,
    ) -> Result<PathBuf, ScriptLanguageSupportError> {
        let root = resolve_path(&self.root_url()).unwrap_or_else(|_| self.root_url());
        let scratch = self.root_url().join(".build");
        self.validate_generated_location(&scratch)?;
        if is_symbolic_link(&scratch) {
            return Err(ScriptLanguageSupportError::Unavailable(
                "The generated Rust analysis cache must not be a symbolic link.".to_string(),
            ));
        }

        let mut modules: Vec<ScriptAnalysisCacheFile> = Vec::new();
        for path in &self.engine_module_paths {
            let base = PathBuf::from(path);
            for member in ["Cargo.toml", "src"] {
                modules.extend(ScriptAnalysisCacheFile::module_files(&base.join(member)));
            }
        }
        modules.extend(
            self.clang_module_map_paths
                .iter()
                .map(|path| ScriptAnalysisCacheFile::new(Path::new(path))),
        );
        let identity = ScriptAnalysisCacheIdentity {
            workspace: root.to_string_lossy().into_owned(),
            executable: ScriptAnalysisCacheFile::new(executable_url),
            // Swift tracked `SWIFT_EXEC`; the Rust compiler comes from `RUSTC`.
            compiler: environment
                .get("RUSTC")
                .filter(|value| !value.is_empty())
                .map(|value| ScriptAnalysisCacheFile::new(Path::new(value))),
            // Swift tracked `SDKSettings.json`; a Rust toolchain's SDK is its
            // sysroot, whose `lib/rustlib` carries the standard-library version.
            sysroot: self
                .resource_directory_url
                .as_ref()
                .or(self.sdk_url.as_ref())
                .map(|url| ScriptAnalysisCacheFile::new(url)),
            modules,
            flags: self.include_flags(),
        };
        let identity_url = self.root_url().join("analysis-environment.json");
        self.validate_generated_location(&identity_url)?;
        let previous = std::fs::read(&identity_url)
            .ok()
            .and_then(|data| serde_json::from_slice::<ScriptAnalysisCacheIdentity>(&data).ok());
        if previous.as_ref() != Some(&identity) && scratch.exists() {
            let _ = std::fs::remove_dir_all(&scratch);
        }
        std::fs::create_dir_all(&scratch).map_err(io_unavailable)?;
        let encoded = serde_json::to_vec(&identity).map_err(io_unavailable)?;
        AtomicFile::write(&encoded, &identity_url, Access::Inherit).map_err(io_unavailable)?;

        // The server also serves the project folder, so the analysis target
        // directory is this package's own setting rather than a command-line
        // flag for every package.
        let configuration = self.root_url().join("rust-analyzer.toml");
        self.validate_generated_location(&configuration)?;
        let configuration_directory = configuration
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.root_url());
        std::fs::create_dir_all(&configuration_directory).map_err(io_unavailable)?;
        let contents = format!(
            "[cargo]\ntargetDir = \"{}\"\n",
            escape_toml_string(&scratch.to_string_lossy())
        );
        AtomicFile::write(contents.as_bytes(), &configuration, Access::Inherit)
            .map_err(io_unavailable)?;
        // Generated and machine-local: keep it out of the project's version
        // control.
        AtomicFile::write(b"*\n", &self.root_url().join(".gitignore"), Access::Inherit)
            .map_err(io_unavailable)?;
        Ok(scratch)
    }
}

fn swift_date(time: SystemTime) -> SwiftDate {
    SwiftDate(
        time.duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs_f64())
            .unwrap_or(0.0)
            - SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64,
    )
}

fn is_symbolic_link(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
}

fn escape_toml_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            other => escaped.push(other),
        }
    }
    escaped
}

fn io_unavailable(error: impl std::fmt::Display) -> ScriptLanguageSupportError {
    ScriptLanguageSupportError::Unavailable(error.to_string())
}
