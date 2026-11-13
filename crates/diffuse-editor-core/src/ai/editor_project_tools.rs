//! `Editor/Sources/EditorCore/AI/EditorProjectTools.swift` (partial).
//!
//! This round lands only the two types at the top of the Swift file:
//! `EditorProjectToolError` and `ProjectCompileReport`. The
//! `extension EditorApplication` (the project-tool executor and dispatcher)
//! is left to a later batch — see the note at the end of this file.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

use crate::scripting::dynamic::dynamic_script_manager::{CompilationStatus, ScriptFile};

/// `public struct EditorProjectToolError: Error, LocalizedError, Sendable`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorProjectToolError {
    pub message: String,
}

impl EditorProjectToolError {
    pub fn new(message: impl Into<String>) -> Self {
        EditorProjectToolError {
            message: message.into(),
        }
    }

    /// Swift's `LocalizedError.errorDescription` (`public var errorDescription:
    /// String? { message }`).
    pub fn error_description(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for EditorProjectToolError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for EditorProjectToolError {}

/// `private final class ProjectCompileReport: @unchecked Sendable`.
///
/// Swift's `NSLock` + `[[String: Any]]` become `Arc<Mutex<Vec<Value>>>` so the
/// report can be shared by the compilation callbacks (§5.5). Each result entry
/// is built from a `BTreeMap`, and the top-level object too, so the
/// `.sortedKeys` JSON output is byte-stable (§5.2 / §5.4).
#[derive(Clone, Default)]
pub struct ProjectCompileReport {
    results: Arc<Mutex<Vec<Value>>>,
}

impl ProjectCompileReport {
    pub fn new() -> Self {
        ProjectCompileReport {
            results: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn append(&self, file: &ScriptFile, status: CompilationStatus) {
        let (succeeded, message) = match &status {
            CompilationStatus::Succeeded => (true, "compiled and loaded".to_string()),
            CompilationStatus::Failed { message } | CompilationStatus::Blocked { message } => {
                (false, message.clone())
            }
            CompilationStatus::Cancelled => (false, "cancelled".to_string()),
            CompilationStatus::Idle | CompilationStatus::Compiling => {
                (false, "not compiled".to_string())
            }
        };
        let diagnostics = grapheme_suffix(&message, 16_384);
        let filename = file
            .url
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut entry = BTreeMap::new();
        entry.insert("filename".to_string(), Value::String(filename));
        entry.insert(
            "identifier".to_string(),
            Value::String(file.identifier.clone()),
        );
        entry.insert("ok".to_string(), Value::Bool(succeeded));
        entry.insert("diagnostics".to_string(), Value::String(diagnostics));
        self.results
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(Value::Object(entry.into_iter().collect()));
    }

    /// `func data() throws -> Data` (`JSONSerialization` with `[.sortedKeys]`).
    pub fn data(&self) -> Result<Vec<u8>, serde_json::Error> {
        let results = self
            .results
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let ok = results
            .iter()
            .all(|entry| entry.get("ok").and_then(Value::as_bool) == Some(true));
        let mut report = BTreeMap::new();
        report.insert("ok".to_string(), Value::Bool(ok));
        report.insert(
            "scripts".to_string(),
            Value::Array(results.iter().cloned().collect()),
        );
        serde_json::to_vec(&report)
    }
}

/// `String(message.suffix(16_384))`: Swift `Character`s are grapheme clusters,
/// so §5.2 requires `unicode-segmentation`, not byte slicing.
fn grapheme_suffix(text: &str, limit: usize) -> String {
    let graphemes: Vec<&str> = text.graphemes(true).collect();
    let start = graphemes.len().saturating_sub(limit);
    graphemes[start..].concat()
}

// ---------------------------------------------------------------------------
// Deferred to a later batch (NOT translated this round):
//
// `extension EditorApplication` — makeProjectToolExecutor, executeProjectTool,
// validateProjectScriptsDirectory, projectScriptURL, boundedScriptData,
// projectOutputError, and the gameplayScriptingAPI documentation constant.
//
// It depends on EditorStore / ProjectToolset / toolAccess / AgentTaskService /
// WorkstationScripts / EditorContent / ScriptDebugState / ProjectExporter and
// other types that are not migrated yet. No empty or stub implementations are
// emitted here; the extension will be written once those anchors exist.
// ---------------------------------------------------------------------------
