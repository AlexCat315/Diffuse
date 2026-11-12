//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/ScriptLanguageModels.swift`.
//!
//! Value types exchanged with the language server: diagnostics, hover,
//! completion and definition results.
//!
//! `ScriptLanguageSource` stays with `DynamicScriptManager.ScriptFile`, which
//! has not been migrated yet.

use crate::scripting::rust_analyzer::language::script_language_position::ScriptLanguageSpan;

// MARK: - Diagnostics

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ScriptDiagnosticSeverity {
    Error,
    Warning,
    Information,
    Hint,
}

impl ScriptDiagnosticSeverity {
    /// LSP numeric values.
    pub const fn raw_value(self) -> i64 {
        match self {
            Self::Error => 1,
            Self::Warning => 2,
            Self::Information => 3,
            Self::Hint => 4,
        }
    }

    pub fn from_raw_value(value: i64) -> Option<Self> {
        match value {
            1 => Some(Self::Error),
            2 => Some(Self::Warning),
            3 => Some(Self::Information),
            4 => Some(Self::Hint),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageDiagnostic {
    pub severity: ScriptDiagnosticSeverity,
    pub start_line: usize,
    pub start_character: usize,
    pub end_line: usize,
    pub end_character: usize,
    pub message: String,
    pub code: Option<String>,
    pub tags: Vec<ScriptDiagnosticTag>,
    /// Other places the diagnostic points at, such as a clashing declaration.
    pub related: Vec<ScriptDiagnosticRelation>,
}

impl ScriptLanguageDiagnostic {
    pub fn new(
        severity: ScriptDiagnosticSeverity,
        start_line: usize,
        start_character: usize,
        end_line: usize,
        end_character: usize,
        message: String,
        code: Option<String>,
    ) -> Self {
        Self {
            severity,
            start_line,
            start_character,
            end_line,
            end_character,
            message,
            code,
            tags: Vec::new(),
            related: Vec::new(),
        }
    }

    /// Swift's `code: String? = nil` default.
    pub fn with_default_code(
        severity: ScriptDiagnosticSeverity,
        start_line: usize,
        start_character: usize,
        end_line: usize,
        end_character: usize,
        message: String,
    ) -> Self {
        Self::new(
            severity,
            start_line,
            start_character,
            end_line,
            end_character,
            message,
            None,
        )
    }

    pub fn id(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}",
            self.start_line, self.start_character, self.end_line, self.end_character, self.message
        )
    }

    pub fn span(&self) -> ScriptLanguageSpan {
        ScriptLanguageSpan::with_corners(
            self.start_line,
            self.start_character,
            self.end_line,
            self.end_character,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptDiagnosticTag {
    Unnecessary,
    Deprecated,
}

impl ScriptDiagnosticTag {
    pub const fn raw_value(self) -> i64 {
        match self {
            Self::Unnecessary => 1,
            Self::Deprecated => 2,
        }
    }

    pub fn from_raw_value(value: i64) -> Option<Self> {
        match value {
            1 => Some(Self::Unnecessary),
            2 => Some(Self::Deprecated),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptDiagnosticRelation {
    pub message: String,
    pub location: ScriptDefinitionLocation,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageDiagnosticUpdate {
    pub source_revision: u64,
    pub script_id: String,
    pub version: Option<i64>,
    pub diagnostics: Vec<ScriptLanguageDiagnostic>,
}

impl ScriptLanguageDiagnosticUpdate {
    pub fn new(
        script_id: String,
        source_revision: u64,
        version: Option<i64>,
        diagnostics: Vec<ScriptLanguageDiagnostic>,
    ) -> Self {
        Self {
            source_revision,
            script_id,
            version,
            diagnostics,
        }
    }
}

// MARK: - Hover

/// Result of `textDocument/hover`.
///
/// `contents` keeps the server's markup mostly intact — SourceKit answers with
/// Markdown declaration blocks — while `plain_text` carries a stripped summary
/// for contexts that render with a single font.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptHoverResult {
    pub contents: String,
    pub kind: ScriptMarkupKind,
    pub plain_text: String,
    pub span: Option<ScriptLanguageSpan>,
}

impl ScriptHoverResult {
    pub fn new(
        contents: String,
        kind: ScriptMarkupKind,
        plain_text: String,
        span: Option<ScriptLanguageSpan>,
    ) -> Self {
        Self {
            contents,
            kind,
            plain_text,
            span,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.plain_text.is_empty() && self.contents.is_empty()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptMarkupKind {
    Markdown,
    Plaintext,
}

impl ScriptMarkupKind {
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Markdown => "markdown",
            Self::Plaintext => "plaintext",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "markdown" => Some(Self::Markdown),
            "plaintext" => Some(Self::Plaintext),
            _ => None,
        }
    }
}

// MARK: - Completion

/// LSP `CompletionItemKind`. Every value outside the spec range folds into
/// [`ScriptCompletionItemKind::Unknown`] rather than failing to decode — an
/// unconstrained server is more common than a bug.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ScriptCompletionItemKind {
    Text,
    Method,
    Function,
    Constructor,
    Field,
    Variable,
    Class,
    Interface,
    Module,
    Property,
    Unit,
    Value,
    Enumeration,
    Keyword,
    Snippet,
    Color,
    File,
    Reference,
    Folder,
    EnumMember,
    Constant,
    Struct,
    Event,
    Operator,
    TypeParameter,
    Unknown,
}

impl ScriptCompletionItemKind {
    pub fn from_raw_value(value: i64) -> Self {
        match value {
            1 => Self::Text,
            2 => Self::Method,
            3 => Self::Function,
            4 => Self::Constructor,
            5 => Self::Field,
            6 => Self::Variable,
            7 => Self::Class,
            8 => Self::Interface,
            9 => Self::Module,
            10 => Self::Property,
            11 => Self::Unit,
            12 => Self::Value,
            13 => Self::Enumeration,
            14 => Self::Keyword,
            15 => Self::Snippet,
            16 => Self::Color,
            17 => Self::File,
            18 => Self::Reference,
            19 => Self::Folder,
            20 => Self::EnumMember,
            21 => Self::Constant,
            22 => Self::Struct,
            23 => Self::Event,
            24 => Self::Operator,
            25 => Self::TypeParameter,
            _ => Self::Unknown,
        }
    }

    pub const fn raw_value(self) -> i64 {
        match self {
            Self::Unknown => 0,
            Self::Text => 1,
            Self::Method => 2,
            Self::Function => 3,
            Self::Constructor => 4,
            Self::Field => 5,
            Self::Variable => 6,
            Self::Class => 7,
            Self::Interface => 8,
            Self::Module => 9,
            Self::Property => 10,
            Self::Unit => 11,
            Self::Value => 12,
            Self::Enumeration => 13,
            Self::Keyword => 14,
            Self::Snippet => 15,
            Self::Color => 16,
            Self::File => 17,
            Self::Reference => 18,
            Self::Folder => 19,
            Self::EnumMember => 20,
            Self::Constant => 21,
            Self::Struct => 22,
            Self::Event => 23,
            Self::Operator => 24,
            Self::TypeParameter => 25,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptCompletionItem {
    pub label: String,
    pub kind: ScriptCompletionItemKind,
    pub detail: Option<String>,
    pub documentation: Option<String>,
    /// Replacement text once snippet placeholders are expanded.
    pub insert_text: String,
    /// Characters that must be replaced ahead of the caret — SourceKit emits
    /// edits reaching back over the partially typed identifier.
    pub replacement: Option<ScriptLanguageSpan>,
    pub additional_edits: Vec<ScriptCompletionTextEdit>,
    pub uses_snippet: bool,
    /// The server's item, kept when it can fill in documentation on request.
    pub(crate) resolution: Option<Vec<u8>>,
    pub filter_text: Option<String>,
    pub sort_text: Option<String>,
}

impl ScriptCompletionItem {
    pub fn new(
        label: String,
        kind: ScriptCompletionItemKind,
        detail: Option<String>,
        documentation: Option<String>,
        insert_text: String,
        replacement: Option<ScriptLanguageSpan>,
        filter_text: Option<String>,
        sort_text: Option<String>,
    ) -> Self {
        Self {
            label,
            kind,
            detail,
            documentation,
            insert_text,
            replacement,
            additional_edits: Vec::new(),
            uses_snippet: false,
            resolution: None,
            filter_text,
            sort_text,
        }
    }

    pub fn id(&self) -> String {
        format!(
            "{}-{}-{}",
            self.label,
            self.kind.raw_value(),
            self.insert_text
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptCompletionTextEdit {
    pub range: ScriptLanguageSpan,
    pub text: String,
}

impl ScriptCompletionTextEdit {
    pub fn new(range: ScriptLanguageSpan, text: String) -> Self {
        Self { range, text }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptCompletionResult {
    pub items: Vec<ScriptCompletionItem>,
    /// True when the server truncated the list; the editor should re-query as
    /// the user narrows the prefix rather than treating this as final.
    pub is_incomplete: bool,
}

impl ScriptCompletionResult {
    pub fn new(items: Vec<ScriptCompletionItem>, is_incomplete: bool) -> Self {
        Self {
            items,
            is_incomplete,
        }
    }

    /// Swift's `static let empty`.
    pub fn empty() -> Self {
        Self::new(Vec::new(), false)
    }
}

// MARK: - Definition

/// Result of `textDocument/definition`, already mapped back from the shadow
/// workspace onto the project's own script identifiers when the target falls
/// inside the current project.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptDefinitionLocation {
    pub document_uri: String,
    /// Identifier of the owning script when the target is one of the project's
    /// scripts; `None` for engine sources opened from outside the mapping.
    pub script_id: Option<String>,
    pub span: ScriptLanguageSpan,
}

impl ScriptDefinitionLocation {
    pub fn new(document_uri: String, script_id: Option<String>, span: ScriptLanguageSpan) -> Self {
        Self {
            document_uri,
            script_id,
            span,
        }
    }
}

// MARK: - Availability

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptLanguageSupportError {
    #[error("Swift language support is unavailable: {0}")]
    Unavailable(String),
}

impl ScriptLanguageSupportError {
    pub fn error_description(&self) -> String {
        match self {
            Self::Unavailable(reason) => {
                format!("Swift language support is unavailable: {reason}")
            }
        }
    }
}

// MARK: - Service state

/// Swift defines this in `ScriptWorkspaceModel.swift`; the language stack and
/// the workspace share it, so the Rust port keeps it beside the other language
/// models.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ScriptLanguageServiceState {
    #[default]
    Inactive,
    Starting,
    Ready,
    Unavailable(String),
}
