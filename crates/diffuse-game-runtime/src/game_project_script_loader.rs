//! Translation of `Editor/Sources/GameRuntime/GameProjectScriptLoader.swift`.
//!
//! Loads only precompiled artifacts; Player never invokes a compiler or executes
//! sources. D1 replaces `SwiftScriptLoader` with `ScriptLoader`, which maps a
//! Rust cdylib and reads the `diffuse_scripts!` catalog.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fmt;
use std::io;
use std::iter::once;
use std::path::{Path, PathBuf};

use cove_logging::{Level, LogEvent, LogSystem};
use diffuse_editor_core::assets::asset_import_resolver::AssetImportResolver;
use diffuse_editor_core::scripting::dynamic::project_compiled_scripts::{
    ProjectCompiledScriptEntry, ProjectCompiledScripts,
};
use diffuse_script::core::script_definition::{JsonValue, ScriptDefinition};
use diffuse_script::dynamic_script::script_loader::{ScriptFactory, ScriptLoadError, ScriptLoader};
use diffuse_script::{Script, ScriptRuntime};

/// Swift's `GameProjectScriptLoadError`.
#[derive(Debug)]
pub enum GameProjectScriptLoadError {
    UnsupportedVersion(i64),
    IncompatibleTarget(String),
    InvalidIdentifier(String),
    InvalidLibraryPath(String),
    CorruptedLibrary(String),
    MissingBindings(Vec<String>),
    /// Swift rethrew library loader errors; Rust names the wrapped error.
    Script(ScriptLoadError),
    Io(io::Error),
    Decode(String),
}

impl fmt::Display for GameProjectScriptLoadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported compiled script version: {version}")
            }
            Self::IncompatibleTarget(target) => write!(
                formatter,
                "compiled scripts target {target}, expected {}",
                ProjectCompiledScripts::current_target()
            ),
            Self::InvalidIdentifier(identifier) => write!(
                formatter,
                "invalid or duplicate compiled script identifier: {identifier}"
            ),
            Self::InvalidLibraryPath(path) => {
                write!(
                    formatter,
                    "compiled script library escapes the project: {path}"
                )
            }
            Self::CorruptedLibrary(path) => {
                write!(
                    formatter,
                    "compiled script library checksum mismatch: {path}"
                )
            }
            Self::MissingBindings(bindings) => {
                write!(
                    formatter,
                    "unresolved game script bindings: {}",
                    bindings.join(", ")
                )
            }
            Self::Script(error) => error.fmt(formatter),
            Self::Io(error) => error.fmt(formatter),
            Self::Decode(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for GameProjectScriptLoadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Script(error) => Some(error),
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<ScriptLoadError> for GameProjectScriptLoadError {
    fn from(error: ScriptLoadError) -> Self {
        Self::Script(error)
    }
}

impl From<io::Error> for GameProjectScriptLoadError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub struct GameProjectScriptLoader {
    loader: ScriptLoader,
}

impl Default for GameProjectScriptLoader {
    fn default() -> Self {
        Self::new()
    }
}

impl GameProjectScriptLoader {
    pub fn new() -> Self {
        Self {
            loader: ScriptLoader::new(),
        }
    }

    pub fn load(
        &self,
        project_directory: &Path,
        runtime: &ScriptRuntime,
    ) -> Result<Vec<ProjectCompiledScriptEntry>, GameProjectScriptLoadError> {
        let manifest_url = project_directory.join(ProjectCompiledScripts::RELATIVE_PATH);
        if !manifest_url.exists() {
            return Ok(Vec::new());
        }
        let data = std::fs::read_to_string(&manifest_url)?;
        let manifest = decode_manifest(&data)?;
        if manifest.version != ProjectCompiledScripts::CURRENT_VERSION {
            return Err(GameProjectScriptLoadError::UnsupportedVersion(
                manifest.version,
            ));
        }
        if manifest.target != ProjectCompiledScripts::current_target() {
            return Err(GameProjectScriptLoadError::IncompatibleTarget(
                manifest.target,
            ));
        }
        let root = canonical_url(project_directory);
        let mut identifiers: BTreeSet<String> = runtime
            .registered_script_identifiers()
            .into_iter()
            .collect();
        let mut libraries: Vec<(&ProjectCompiledScriptEntry, PathBuf)> = Vec::new();
        for entry in &manifest.entries {
            for identifier in once(&entry.identifier).chain(entry.legacy_identifiers.iter()) {
                if !identifier.starts_with("scripts.") || !identifiers.insert(identifier.clone()) {
                    return Err(GameProjectScriptLoadError::InvalidIdentifier(
                        identifier.clone(),
                    ));
                }
            }
            let Some(relative_path) =
                AssetImportResolver::sanitized_relative_path(&entry.library_path)
            else {
                return Err(GameProjectScriptLoadError::InvalidLibraryPath(
                    entry.library_path.clone(),
                ));
            };
            if !relative_path.starts_with("Scripts/Compiled/") {
                return Err(GameProjectScriptLoadError::InvalidLibraryPath(
                    entry.library_path.clone(),
                ));
            }
            let library = canonical_url(&root.join(relative_path));
            if !path_contains(&library, &root, false) {
                return Err(GameProjectScriptLoadError::InvalidLibraryPath(
                    entry.library_path.clone(),
                ));
            }
            let digest = ProjectCompiledScripts::digest(&std::fs::read(&library)?);
            if digest != entry.sha256 {
                return Err(GameProjectScriptLoadError::CorruptedLibrary(
                    entry.library_path.clone(),
                ));
            }
            libraries.push((entry, library));
        }

        // Validate the entire document before mapping any project code. Register
        // factories only after all libraries have loaded successfully.
        let factories: Vec<(&ProjectCompiledScriptEntry, ScriptFactory)> = libraries
            .iter()
            .map(|(entry, library)| {
                let factory = load_entry_factory(
                    &self.loader,
                    &entry.identifier,
                    library,
                    &entry.display_name,
                )?;
                Ok((*entry, factory))
            })
            .collect::<Result<_, ScriptLoadError>>()?;
        for (entry, factory) in factories {
            let definition = self.loader.definition(&entry.identifier);
            for identifier in once(&entry.identifier).chain(entry.legacy_identifiers.iter()) {
                let factory = factory.clone();
                runtime.register_factory(Some(identifier), "{}", definition.clone(), move || {
                    // `register_factory` takes infallible factories. Swift's
                    // runtime kept the throwing factory and surfaced the error at
                    // instantiation; the Rust runtime has no fallible slot, so a
                    // failure is reported and the binding stays inert.
                    factory().unwrap_or_else(|error| {
                        LogSystem::logger("com.cove.player.scripting").log(&LogEvent::new(
                            Level::Error,
                            format!("compiled script factory failed: {error}"),
                        ));
                        Script::new(None, None, None, None)
                    })
                });
            }
        }
        Ok(manifest.entries)
    }
}

/// Swift asked `SwiftScriptLoader` for one library per identifier. D1 compiles
/// every project script into one cdylib whose catalog names are Rust type names,
/// which `ProjectCompiledScripts` does not record. A single-script library loads
/// directly; a shared library selects the catalog entry by `displayName`, then
/// by its PascalCase form, and otherwise reports the ambiguity instead of
/// guessing.
fn load_entry_factory(
    loader: &ScriptLoader,
    identifier: &str,
    library: &Path,
    display_name: &str,
) -> Result<ScriptFactory, ScriptLoadError> {
    let library_path = library.to_string_lossy();
    match loader.load_factory(identifier, &library_path) {
        Ok(factory) => Ok(factory),
        Err(ScriptLoadError::ScriptSelectionRequired(names)) => {
            let Some(name) = matching_catalog_name(display_name, &names) else {
                return Err(ScriptLoadError::ScriptSelectionRequired(names));
            };
            loader.load_named_factory(identifier, &library_path, &name)
        }
        Err(error) => Err(error),
    }
}

fn matching_catalog_name(display_name: &str, names: &[String]) -> Option<String> {
    if let Some(name) = names.iter().find(|name| name.as_str() == display_name) {
        return Some(name.clone());
    }
    let lower = display_name.to_lowercase();
    let insensitive: Vec<&String> = names
        .iter()
        .filter(|name| name.to_lowercase() == lower)
        .collect();
    if insensitive.len() == 1 {
        return Some(insensitive[0].clone());
    }
    let pascal = pascal_case(display_name).to_lowercase();
    let matches: Vec<&String> = names
        .iter()
        .filter(|name| name.to_lowercase() == pascal)
        .collect();
    if matches.len() == 1 {
        Some(matches[0].clone())
    } else {
        None
    }
}

fn pascal_case(name: &str) -> String {
    let mut result = String::new();
    for segment in name.split(|character: char| !character.is_alphanumeric()) {
        let mut characters = segment.chars();
        let Some(first) = characters.next() else {
            continue;
        };
        result.extend(first.to_uppercase());
        result.push_str(characters.as_str());
    }
    result
}

/// `cove_system::paths::PathIdentity` is not a dependency of this crate; this is
/// its longest-existing-ancestor resolution reduced to what the containment
/// check needs.
fn canonical_url(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    let mut ancestor = absolute;
    let mut suffix: Vec<OsString> = Vec::new();
    while !ancestor.exists() {
        let Some(name) = ancestor.file_name().map(std::ffi::OsStr::to_os_string) else {
            break;
        };
        let Some(parent) = ancestor.parent().map(Path::to_path_buf) else {
            break;
        };
        if parent == ancestor {
            break;
        }
        suffix.push(name);
        ancestor = parent;
    }
    let mut result = std::fs::canonicalize(&ancestor).unwrap_or(ancestor);
    for component in suffix.iter().rev() {
        result.push(component);
    }
    result
}

fn path_contains(candidate: &Path, root: &Path, including_root: bool) -> bool {
    let candidate = canonical_url(candidate);
    let root = canonical_url(root);
    candidate.starts_with(&root) && (including_root || candidate != root)
}

/// `serde_json` is not a dependency of this crate; the std-only parser behind
/// `ScriptDefinition::decode_parameters` is the only public JSON reader here.
/// It reports malformed input as an empty object, so every required field is
/// checked explicitly and a missing one fails decoding.
fn decode_manifest(text: &str) -> Result<ProjectCompiledScripts, GameProjectScriptLoadError> {
    let document = ScriptDefinition::decode_parameters(text);
    let version = required_i64(&document, "version")?;
    let target = required_string(&document, "target")?;
    let entries = document
        .get("entries")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| decode_error("compiled script manifest is missing its entries array"))?;
    let mut compiled = Vec::with_capacity(entries.len());
    for entry in entries {
        let object = entry
            .as_object()
            .ok_or_else(|| decode_error("compiled script entry is not an object"))?;
        let identifier = required_string(object, "identifier")?;
        let display_name = required_string(object, "displayName")?;
        let library_path = required_string(object, "libraryPath")?;
        let sha256 = required_string(object, "sha256")?;
        let legacy = object
            .get("legacyIdentifiers")
            .and_then(JsonValue::as_array)
            .ok_or_else(|| {
                decode_error("compiled script entry is missing its legacyIdentifiers array")
            })?;
        let legacy_identifiers = legacy
            .iter()
            .map(|value| {
                value.as_str().map(str::to_owned).ok_or_else(|| {
                    decode_error("compiled script legacy identifier is not a string")
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        compiled.push(ProjectCompiledScriptEntry::new(
            identifier,
            display_name,
            legacy_identifiers,
            library_path,
            sha256,
        ));
    }
    Ok(ProjectCompiledScripts::with_target(
        compiled, version, target,
    ))
}

fn required_string(
    object: &std::collections::BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<String, GameProjectScriptLoadError> {
    object
        .get(key)
        .and_then(JsonValue::as_str)
        .map(str::to_owned)
        .ok_or_else(|| decode_error(format!("compiled script manifest is missing field {key}")))
}

fn required_i64(
    object: &std::collections::BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<i64, GameProjectScriptLoadError> {
    object
        .get(key)
        .and_then(integer_value)
        .ok_or_else(|| decode_error(format!("compiled script manifest is missing integer {key}")))
}

fn integer_value(value: &JsonValue) -> Option<i64> {
    match value {
        JsonValue::Integer(value) => Some(*value),
        JsonValue::Unsigned(value) => i64::try_from(*value).ok(),
        JsonValue::Number(value)
            if value.is_finite()
                && value.fract() == 0.0
                && *value >= i64::MIN as f64
                && *value <= i64::MAX as f64 =>
        {
            Some(*value as i64)
        }
        JsonValue::Float(value) if value.is_finite() && value.fract() == 0.0 => Some(*value as i64),
        _ => None,
    }
}

fn decode_error(message: impl Into<String>) -> GameProjectScriptLoadError {
    GameProjectScriptLoadError::Decode(message.into())
}
