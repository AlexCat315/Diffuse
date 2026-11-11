//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/Editing.swift`.
//!
//! Edits, code actions and the semantic context that ties a language-server
//! reply back to the script revisions it was computed from.

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

use diffuse_plugin::Uuid;

use crate::scripting::rust_analyzer::language::script_language_models::ScriptCompletionTextEdit;
use crate::scripting::rust_analyzer::language::script_language_position::ScriptLanguageSpan;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptWorkspaceEdit {
    pub documents: Vec<ScriptDocumentEdit>,
}

impl ScriptWorkspaceEdit {
    pub fn new(documents: Vec<ScriptDocumentEdit>) -> Self {
        Self { documents }
    }

    pub fn is_empty(&self) -> bool {
        self.documents
            .iter()
            .all(|document| document.edits.is_empty())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptDocumentEdit {
    pub script_id: String,
    pub source_revision: u64,
    pub edits: Vec<ScriptCompletionTextEdit>,
}

impl ScriptDocumentEdit {
    pub fn new(
        script_id: String,
        source_revision: u64,
        edits: Vec<ScriptCompletionTextEdit>,
    ) -> Self {
        Self {
            script_id,
            source_revision,
            edits,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptRenamePreparation {
    pub range: ScriptLanguageSpan,
    pub placeholder: Option<String>,
}

impl ScriptRenamePreparation {
    pub fn new(range: ScriptLanguageSpan, placeholder: Option<String>) -> Self {
        Self { range, placeholder }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptCodeAction {
    pub title: String,
    pub kind: Option<String>,
    pub is_preferred: bool,
    pub disabled_reason: Option<String>,
    pub edit: Option<ScriptWorkspaceEdit>,
    pub(crate) resolution: Option<Vec<u8>>,
    pub(crate) context: ScriptSemanticContext,
}

impl ScriptCodeAction {
    pub fn new(
        title: String,
        kind: Option<String>,
        is_preferred: bool,
        disabled_reason: Option<String>,
        edit: Option<ScriptWorkspaceEdit>,
        resolution: Option<Vec<u8>>,
        context: ScriptSemanticContext,
    ) -> Self {
        Self {
            title,
            kind,
            is_preferred,
            disabled_reason,
            edit,
            resolution,
            context,
        }
    }

    pub fn needs_resolution(&self) -> bool {
        self.edit.is_none() && self.disabled_reason.is_none() && self.resolution.is_some()
    }

    pub fn id(&self) -> String {
        format!("{}|{}", self.title, self.kind.as_deref().unwrap_or(""))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptLanguageEditError {
    #[error("The language server returned an invalid edit.")]
    MalformedReply,
    #[error("The language server attempted to edit a file outside this script workspace: {0}")]
    ExternalDocument(String),
    #[error("Creating, moving, or deleting files through a language action is not supported.")]
    UnsupportedResourceOperation,
    #[error("The script changed while the language action was running: {0}")]
    StaleDocument(String),
    #[error("This language action requires a server command that cannot be applied safely.")]
    UnsupportedCommand,
    #[error("The language server returned an invalid text range.")]
    InvalidRange,
    #[error("The language server returned overlapping text edits.")]
    OverlappingEdits,
    #[error("The language server returned multiple edit groups for the same document.")]
    DuplicateDocument,
    #[error("There is no language operation to undo or redo.")]
    NoHistory,
    #[error("{0}")]
    DisabledAction(String),
}

impl ScriptLanguageEditError {
    pub fn error_description(&self) -> String {
        self.to_string()
    }
}

/// Revision/version snapshot a language-server reply was requested against.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptSemanticContext {
    pub(crate) documents: BTreeMap<String, ScriptSemanticDocument>,
    pub(crate) generation: Uuid,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptSemanticDocument {
    pub script_id: String,
    pub revision: u64,
    pub version: i64,
}

impl ScriptSemanticDocument {
    pub fn new(script_id: String, revision: u64, version: i64) -> Self {
        Self {
            script_id,
            revision,
            version,
        }
    }
}

impl ScriptSemanticContext {
    /// Swift's `generation: UUID = UUID()` default.
    pub fn new(documents: BTreeMap<String, ScriptSemanticDocument>) -> Self {
        Self {
            documents,
            generation: Uuid::new(),
        }
    }

    pub fn with_generation(
        documents: BTreeMap<String, ScriptSemanticDocument>,
        generation: Uuid,
    ) -> Self {
        Self {
            documents,
            generation,
        }
    }

    pub fn document(&self, uri: &str) -> Option<&ScriptSemanticDocument> {
        self.documents.get(&Self::document_key(uri))
    }

    /// `URL(string: uri)` that `isFileURL`, resolved and standardized; every
    /// other spelling is its own key.
    pub fn document_key(uri: &str) -> String {
        let Some(path) = file_url_path(uri) else {
            return uri.to_string();
        };
        file_url_string(&standardized_path(&path))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptSemanticResponse {
    pub payload: Option<Vec<u8>>,
    pub context: ScriptSemanticContext,
}

impl ScriptSemanticResponse {
    pub fn new(payload: Option<Vec<u8>>, context: ScriptSemanticContext) -> Self {
        Self { payload, context }
    }
}

/// `URL(string: uri)?.isFileURL == true` → path; `None` for anything else.
fn file_url_path(uri: &str) -> Option<PathBuf> {
    if !uri
        .get(..5)
        .is_some_and(|scheme| scheme.eq_ignore_ascii_case("file:"))
    {
        return None;
    }
    let rest = &uri[5..];
    let path = if let Some(rest) = rest.strip_prefix("//") {
        let (host, path) = match rest.find('/') {
            Some(index) => (&rest[..index], &rest[index..]),
            None => (rest, ""),
        };
        if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
            path.to_string()
        } else {
            format!("//{host}{path}")
        }
    } else {
        rest.to_string()
    };
    let decoded = percent_decode(&path)?;
    if decoded.is_empty() {
        return None;
    }
    Some(PathBuf::from(normalize_platform_path(decoded)))
}

fn normalize_platform_path(path: String) -> String {
    #[cfg(windows)]
    {
        // `file:///C:/x` parses to `/C:/x`; the drive letter makes the leading
        // separator part of the URI spelling only.
        let bytes = path.as_bytes();
        if bytes.len() >= 3
            && bytes[0] == b'/'
            && bytes[1].is_ascii_alphabetic()
            && bytes[2] == b':'
        {
            return path[1..].to_string();
        }
    }
    path
}

/// Percent-decodes `%HH` escapes; invalid escapes make the URL unparseable,
/// matching `URL(string:)` returning nil.
fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = *bytes.get(index + 1)?;
            let low = *bytes.get(index + 2)?;
            let digit = |byte: u8| -> Option<u8> {
                match byte {
                    b'0'..=b'9' => Some(byte - b'0'),
                    b'a'..=b'f' => Some(byte - b'a' + 10),
                    b'A'..=b'F' => Some(byte - b'A' + 10),
                    _ => None,
                }
            };
            decoded.push(digit(high)? << 4 | digit(low)?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

/// `URL.standardizedFileURL.absoluteString` for a path, with forward slashes on
/// every platform.
fn file_url_string(path: &Path) -> String {
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let text = absolute.to_string_lossy().replace('\\', "/");
    let mut encoded = String::from("file://");
    if !text.starts_with('/') {
        encoded.push('/');
    }
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(byte as char);
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    encoded
}

/// Canonical form when the path exists, otherwise an absolute lexically
/// normalized path — matching `standardizedFileURL`.
fn standardized_path(path: &Path) -> PathBuf {
    if let Ok(canonical) = std::fs::canonicalize(path) {
        return canonical;
    }
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
