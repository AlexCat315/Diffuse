//! Translation of
//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/ScriptLanguageWorkspace.swift`.
//!
//! D1 rewrite: the generated SwiftPM package (`Package.swift`, `.swiftmodule`
//! include paths and `swiftc` settings) becomes a cargo workspace
//! (`Cargo.toml`, one `cdylib` target per script, the engine script crates as
//! path dependencies and rustc include flags). The document/URL bookkeeping,
//! the "write only when changed" rule and every validation branch are
//! unchanged.
//!
//! Persisted bytes stay Swift-compatible (§5.4): generated files are written
//! as the UTF-8 bytes of their `String`, through
//! `cove_system::atomic_file::AtomicFile`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;

use crate::scripting::dynamic::dynamic_script_manager::ScriptFile;
use crate::scripting::rust_analyzer::language::script_language_models::ScriptLanguageSupportError;

/// Swift's nested `ScriptLanguageWorkspace.Document`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageDocument {
    pub script_id: String,
    pub source_url: PathBuf,
    pub analysis_url: PathBuf,
    pub target_name: String,
}

/// The generated shadow workspace that rust-analyzer analyzes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageWorkspace {
    pub scripts_directory_url: PathBuf,
    /// D1: directories of the engine's script crates (Swift's `.swiftmodule`
    /// `-I` paths), so scripts can `use diffuse_scene::…`.
    pub engine_module_paths: Vec<String>,
    pub clang_module_map_paths: Vec<String>,
    pub clang_include_paths: Vec<String>,
    pub sdk_url: Option<PathBuf>,
    pub resource_directory_url: Option<PathBuf>,
}

impl ScriptLanguageWorkspace {
    pub fn new(
        scripts_directory_url: PathBuf,
        engine_module_paths: Vec<String>,
        clang_module_map_paths: Vec<String>,
        clang_include_paths: Vec<String>,
        sdk_url: Option<PathBuf>,
        resource_directory_url: Option<PathBuf>,
    ) -> Self {
        Self {
            scripts_directory_url,
            engine_module_paths,
            clang_module_map_paths,
            clang_include_paths,
            sdk_url,
            resource_directory_url,
        }
    }

    /// The project folder, served as a second language-server root so Rust
    /// files anywhere in it, and its cargo workspace, are analyzed in place.
    pub fn project_root_url(&self) -> PathBuf {
        self.scripts_directory_url
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default()
    }

    /// The generated workspace lives in the project's machine-local state, so
    /// a project without scripts never grows a `Scripts` folder.
    pub fn root_url(&self) -> PathBuf {
        self.project_root_url().join(".cove").join("rust-analyzer")
    }

    /// D1: Swift's `Package.swift` becomes the cargo manifest.
    pub fn package_manifest_url(&self) -> PathBuf {
        self.root_url().join("Cargo.toml")
    }

    /// A project file is analyzed where it is; nothing is written for it.
    pub fn project_document(file: &ScriptFile) -> ScriptLanguageDocument {
        ScriptLanguageDocument {
            script_id: file.identifier.clone(),
            source_url: file.url.clone(),
            analysis_url: file.url.clone(),
            target_name: String::new(),
        }
    }

    pub fn synchronize(
        &self,
        scripts: &[(ScriptFile, String)],
        project_sources: &[ScriptFile],
    ) -> Result<BTreeMap<String, ScriptLanguageDocument>, ScriptLanguageSupportError> {
        let sources_url = self.root_url().join("Sources");
        self.validate_generated_location(&sources_url)?;
        std::fs::create_dir_all(&sources_url).map_err(io_unavailable)?;

        let documents: Vec<ScriptLanguageDocument> = scripts
            .iter()
            .map(|(file, _)| {
                let target_name = Self::target_name(&file.identifier);
                let target_directory = sources_url.join(&target_name);
                ScriptLanguageDocument {
                    script_id: file.identifier.clone(),
                    source_url: file.url.clone(),
                    // D1: Swift's `GameScript.swift` becomes `src/lib.rs`.
                    analysis_url: target_directory.join("src").join("lib.rs"),
                    target_name,
                }
            })
            .collect();
        let active_targets: BTreeSet<String> = documents
            .iter()
            .map(|document| document.target_name.clone())
            .collect();

        for (file, source) in scripts {
            let Some(document) = documents
                .iter()
                .find(|document| document.script_id == file.identifier)
            else {
                continue;
            };
            self.validate_generated_location(&document.analysis_url)?;
            let parent = document
                .analysis_url
                .parent()
                .unwrap_or_else(|| Path::new("."));
            std::fs::create_dir_all(parent).map_err(io_unavailable)?;
            self.write_if_changed(source, &document.analysis_url)?;
        }

        if let Ok(children) = std::fs::read_dir(&sources_url) {
            for child in children.flatten() {
                let name = child.file_name().to_string_lossy().into_owned();
                if name.starts_with("Script_") && !active_targets.contains(&name) {
                    let path = child.path();
                    // Swift's `try? removeItem` ignores failures.
                    let _ = std::fs::remove_dir_all(&path).or_else(|_| std::fs::remove_file(&path));
                }
            }
        }

        let manifest = self.manifest(&documents);
        self.write_if_changed(&manifest, &self.package_manifest_url())?;
        Ok(documents
            .into_iter()
            .chain(project_sources.iter().map(Self::project_document))
            .map(|document| (document.script_id.clone(), document))
            .collect())
    }

    pub fn write_analysis_source(
        &self,
        source: &str,
        document: &ScriptLanguageDocument,
    ) -> Result<(), ScriptLanguageSupportError> {
        self.write_if_changed(source, &document.analysis_url)
    }

    pub fn validate_generated_location(
        &self,
        url: &Path,
    ) -> Result<(), ScriptLanguageSupportError> {
        let failure = || {
            ScriptLanguageSupportError::Unavailable(
                "The generated Rust analysis workspace must remain inside the project's .cove folder."
                    .to_string(),
            )
        };
        let state = path_components(&self.project_root_url().join(".cove"));
        let root = path_components(&self.root_url());
        let target = path_components(url);
        // Swift's `url.isFileURL`: every generated URL is an absolute file URL.
        if !(url.is_absolute()
            && root.len() > state.len()
            && root.starts_with(&state)
            && target.len() > root.len()
            && target.starts_with(&root))
        {
            return Err(failure());
        }
        // Validate each lexical component before creating it. Windows changes
        // the spelling of existing paths when resolving symlinks, so comparing
        // independently resolved existing and future paths is not reliable.
        let project_root = self.project_root_url();
        let prefix = path_components(&project_root).len();
        let mut ancestor = standardized_lexical(&project_root);
        for component in lexical_path_components(url).iter().skip(prefix) {
            ancestor.push(component.as_str());
            if is_symbolic_link(&ancestor) {
                return Err(failure());
            }
        }
        Ok(())
    }

    pub fn target_name(script_id: &str) -> String {
        let base: String = script_id
            .chars()
            .map(|character| {
                if character.is_alphanumeric() {
                    character.to_string()
                } else {
                    "_".to_string()
                }
            })
            .collect();
        let stable_hash = script_id
            .as_bytes()
            .iter()
            .fold(0xcbf2_9ce4_8422_2325u64, |hash, byte| {
                (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
            });
        format!("Script_{base}_{stable_hash:x}")
    }

    /// D1: the Swift/Clang compiler flags become rustc arguments. They are the
    /// same strings the analysis cache tracks and the LSP receives as
    /// `rustcFlags`, so the server sees exactly the engine crates the dynamic
    /// script compiler uses instead of building the whole engine.
    pub fn include_flags(&self) -> Vec<String> {
        let mut flags: Vec<String> = Vec::new();
        // Swift `-sdk` / `-resource-dir` → rustc `--sysroot` / `-L`.
        if let Some(sdk_url) = &self.sdk_url {
            flags.push("--sysroot".to_string());
            flags.push(sdk_url.to_string_lossy().into_owned());
        }
        if let Some(resource_directory_url) = &self.resource_directory_url {
            flags.push("-L".to_string());
            flags.push(resource_directory_url.to_string_lossy().into_owned());
        }
        // Swift `-I` for `.swiftmodule` files → `-L dependency=` for engine
        // script crates.
        for path in &self.engine_module_paths {
            flags.push("-L".to_string());
            flags.push(format!("dependency={path}"));
        }
        // Swift `-Xcc -I<path>` / `-fmodule-map-file=` → rustc native/cfg.
        for path in &self.clang_include_paths {
            flags.push("-L".to_string());
            flags.push(format!("native={path}"));
        }
        for path in &self.clang_module_map_paths {
            flags.push("--cfg".to_string());
            flags.push(format!("cove_module_map=\"{path}\""));
        }
        flags
    }

    /// Generates the cargo manifest: one `cdylib` target per script (mirroring
    /// Swift's `targets: [...]`), the engine script crates as path
    /// dependencies, and the analysis flags as package metadata.
    fn manifest(&self, documents: &[ScriptLanguageDocument]) -> String {
        // Swift's `String(reflecting:)` quoted each flag into
        // `.unsafeFlags([...])`; the TOML array keeps the same shape.
        let settings = format!(
            "[{}]",
            self.include_flags()
                .iter()
                .map(|flag| toml_string(flag))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let targets = documents
            .iter()
            .map(|document| {
                format!(
                    "[[example]]\nname = {}\npath = {}\ncrate-type = [\"cdylib\"]\n",
                    toml_string(&document.target_name),
                    toml_string(&format!("Sources/{}/src/lib.rs", document.target_name)),
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        let dependencies = self
            .engine_module_paths
            .iter()
            .map(|path| {
                let name = Path::new(path)
                    .file_name()
                    .map(|name| name.to_string_lossy().replace('-', "_"))
                    .unwrap_or_else(|| "engine_script".to_string());
                format!("{name} = {{ path = {} }}", toml_string(path))
            })
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "// Generated by Diffuse for rust-analyzer analysis; do not edit.\n\
             [package]\n\
             name = \"CoveScriptAnalysis\"\n\
             version = \"0.0.0\"\n\
             edition = \"2024\"\n\
             rust-version = \"1.90\"\n\
             \n\
             [package.metadata.diffuse]\n\
             rustflags = {settings}\n\
             \n\
             [workspace]\n\
             \n\
             [dependencies]\n\
             {dependencies}\n\
             \n\
             {targets}"
        )
    }

    fn write_if_changed(
        &self,
        contents: &str,
        url: &Path,
    ) -> Result<(), ScriptLanguageSupportError> {
        self.validate_generated_location(url)?;
        // Swift's `String(contentsOf:encoding:.utf8)` read; a missing or
        // non-UTF-8 file is rewritten, matching `try?`.
        if std::fs::read_to_string(url)
            .map(|current| current == contents)
            .unwrap_or(false)
        {
            return Ok(());
        }
        let parent = url.parent().unwrap_or_else(|| Path::new("."));
        std::fs::create_dir_all(parent).map_err(io_unavailable)?;
        // §5.4: `Data(contents.utf8)` byte-for-byte, published atomically.
        AtomicFile::write(contents.as_bytes(), url, Access::Inherit).map_err(io_unavailable)
    }
}

fn io_unavailable(error: impl std::fmt::Display) -> ScriptLanguageSupportError {
    ScriptLanguageSupportError::Unavailable(error.to_string())
}

fn is_symbolic_link(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
}

/// `URL.standardizedFileURL` without resolving symlinks: an absolute,
/// lexically normalized path. Swift compares lexical components on purpose
/// (Windows changes the spelling of existing resolved paths).
fn standardized_lexical(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
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

fn lexical_path_components(path: &Path) -> Vec<String> {
    standardized_lexical(path)
        .components()
        .map(|component| component.as_os_str().to_string_lossy().into_owned())
        .collect()
}

/// Swift's `components(_:)` lowercased path components on Windows only; the
/// `#[cfg]` pair covers every other platform unchanged.
#[cfg(windows)]
fn path_components(path: &Path) -> Vec<String> {
    lexical_path_components(path)
        .into_iter()
        .map(|component| component.to_lowercase())
        .collect()
}

#[cfg(not(windows))]
fn path_components(path: &Path) -> Vec<String> {
    lexical_path_components(path)
}

/// Swift's `String(reflecting:)` for manifest/flag string literals.
fn toml_string(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for character in value.chars() {
        match character {
            '\\' => quoted.push_str("\\\\"),
            '"' => quoted.push_str("\\\""),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}
