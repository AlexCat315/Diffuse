//! A language the editor edits, with its declarative colouring and heading
//! rules.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Languages/Language.swift`.

use serde::{Deserialize, Serialize};

use crate::contract::plugin_json::PluginJSON;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyntaxGrammarContribution {
    pub rules: Vec<SyntaxRuleContribution>,
}

impl SyntaxGrammarContribution {
    pub fn new(rules: Vec<SyntaxRuleContribution>) -> Self {
        SyntaxGrammarContribution { rules }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyntaxRuleContribution {
    pub pattern: String,
    pub token: String,
}

impl SyntaxRuleContribution {
    pub fn new(pattern: impl Into<String>, token: impl Into<String>) -> Self {
        SyntaxRuleContribution {
            pattern: pattern.into(),
            token: token.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlineContribution {
    pub rules: Vec<OutlineRuleContribution>,
}

impl OutlineContribution {
    pub fn new(rules: Vec<OutlineRuleContribution>) -> Self {
        OutlineContribution { rules }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlineRuleContribution {
    pub pattern: String,
    pub level: i64,
}

impl OutlineRuleContribution {
    pub fn new(pattern: impl Into<String>, level: i64) -> Self {
        OutlineRuleContribution {
            pattern: pattern.into(),
            level,
        }
    }
}

/// A capability that formats a whole document. The entry point takes
/// the step/document format input type and returns the formatted text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FormatContribution {
    pub entry_point: String,
}

impl FormatContribution {
    pub fn new(entry_point: impl Into<String>) -> Self {
        FormatContribution {
            entry_point: entry_point.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyntaxToken {
    Keyword,
    Type,
    Function,
    String,
    Number,
    Comment,
    Attribute,
    Directive,
}

impl SyntaxToken {
    /// Swift's `CaseIterable` order.
    pub const ALL: [SyntaxToken; 8] = [
        SyntaxToken::Keyword,
        SyntaxToken::Type,
        SyntaxToken::Function,
        SyntaxToken::String,
        SyntaxToken::Number,
        SyntaxToken::Comment,
        SyntaxToken::Attribute,
        SyntaxToken::Directive,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            SyntaxToken::Keyword => "keyword",
            SyntaxToken::Type => "type",
            SyntaxToken::Function => "function",
            SyntaxToken::String => "string",
            SyntaxToken::Number => "number",
            SyntaxToken::Comment => "comment",
            SyntaxToken::Attribute => "attribute",
            SyntaxToken::Directive => "directive",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<SyntaxToken> {
        Self::ALL
            .into_iter()
            .find(|token| token.raw_value() == value)
    }
}

/// A language the editor edits: the files that are written in it and, when the
/// package runs one, its language server. The server is a process permission of
/// the package; its traffic flows through the permission's entry point.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanguageContribution {
    /// The LSP language identifier, such as `swift`.
    pub id: String,
    pub title: String,
    /// File name extensions without the dot.
    pub extensions: Vec<String>,
    /// The icon key, when it differs from `id`; such as `text` for `plaintext`.
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub server: Option<LanguageServerContribution>,
    /// Declarative colouring rules the host runs natively.
    #[serde(default)]
    pub grammar: Option<SyntaxGrammarContribution>,
    /// Declarative heading rules the host runs natively.
    #[serde(default)]
    pub outline: Option<OutlineContribution>,
    /// The capability that formats this language's whole document.
    #[serde(default)]
    pub format: Option<FormatContribution>,
}

impl LanguageContribution {
    pub fn new(id: impl Into<String>, title: impl Into<String>, extensions: Vec<String>) -> Self {
        LanguageContribution {
            id: id.into(),
            title: title.into(),
            extensions,
            icon: None,
            server: None,
            grammar: None,
            outline: None,
            format: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanguageServerContribution {
    /// The id of the process permission that starts the server.
    pub process: String,
    /// Sent as `initializationOptions`; the editor may add host facts to it.
    #[serde(default)]
    pub initialization_options: Option<PluginJSON>,
    /// Answers `workspace/configuration`, keyed by section.
    #[serde(default)]
    pub settings: Option<PluginJSON>,
    /// File names, beside the language's extensions, whose changes on disk the
    /// server is told about, such as a package manifest.
    #[serde(default)]
    pub watched_files: Option<Vec<String>>,
}

impl LanguageServerContribution {
    pub fn new(process: impl Into<String>) -> Self {
        LanguageServerContribution {
            process: process.into(),
            initialization_options: None,
            settings: None,
            watched_files: None,
        }
    }
}
