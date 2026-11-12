//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/Details.swift`.
//!
//! Language-service health, indexing progress and the bounded log the settings
//! pane shows. `ScriptLanguageSemanticEvidence` stays with
//! `ScriptLanguageReplies`, which has not been migrated yet.

use std::time::SystemTime;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScriptAnalysisHealth {
    Checking,
    Healthy,
    Degraded(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptIndexProgress {
    pub title: String,
    pub message: Option<String>,
    pub percentage: Option<i64>,
}

impl ScriptIndexProgress {
    pub fn new(title: String, message: Option<String>, percentage: Option<i64>) -> Self {
        Self {
            title,
            message,
            percentage,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageLogEntry {
    pub id: u64,
    pub date: SystemTime,
    pub level: ScriptLanguageLogLevel,
    pub message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptLanguageLogLevel {
    Debug,
    Info,
    Warning,
    Error,
}

impl ScriptLanguageLogLevel {
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Debug => "debug",
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "debug" => Some(Self::Debug),
            "info" => Some(Self::Info),
            "warning" => Some(Self::Warning),
            "error" => Some(Self::Error),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageServiceDetails {
    pub revision: u64,
    pub health: ScriptAnalysisHealth,
    pub indexing: Option<ScriptIndexProgress>,
    pub logs: Vec<ScriptLanguageLogEntry>,
    pub resident_memory_bytes: Option<u64>,
    pub executable_path: String,
}

impl ScriptLanguageServiceDetails {
    pub fn new(executable_path: String) -> Self {
        Self {
            revision: 0,
            health: ScriptAnalysisHealth::Checking,
            indexing: None,
            logs: Vec::new(),
            resident_memory_bytes: None,
            executable_path,
        }
    }

    /// Swift's `record(_:level:)` with its `level: .info` default.
    pub fn record_with_default(&mut self, message: &str) {
        self.record(message, ScriptLanguageLogLevel::Info);
    }

    pub fn record(&mut self, message: &str, level: ScriptLanguageLogLevel) {
        self.revision = self.revision.wrapping_add(1);
        self.logs.push(ScriptLanguageLogEntry {
            id: self.revision,
            date: SystemTime::now(),
            level,
            message: message.chars().take(8_192).collect(),
        });
        if self.logs.len() > 300 {
            let excess = self.logs.len() - 300;
            self.logs.drain(..excess);
        }
    }
}

/// Methods whose non-empty replies prove semantic analysis is available:
/// syntax-only results (formatting, code actions, empty completion/symbols) do
/// not count.
pub enum ScriptLanguageSemanticEvidence {}

impl ScriptLanguageSemanticEvidence {
    pub fn confirms_analysis(method: &str, payload: Option<&[u8]>) -> bool {
        use super::assistance_replies::ScriptAssistanceReplies;
        use super::script_language_protocol::ScriptLanguageReplies;
        match method {
            "textDocument/hover" => {
                ScriptLanguageReplies::parse_hover(payload).is_some_and(|result| !result.is_empty())
            }
            "textDocument/completion" => !ScriptLanguageReplies::parse_completion(payload)
                .items
                .is_empty(),
            "textDocument/definition" | "textDocument/references" => {
                !ScriptLanguageReplies::parse_definition(payload).is_empty()
            }
            "textDocument/signatureHelp" => ScriptAssistanceReplies::signatures(payload).is_some(),
            _ => false,
        }
    }
}
