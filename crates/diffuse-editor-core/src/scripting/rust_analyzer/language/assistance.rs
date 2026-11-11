//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/Assistance.swift`.

use crate::scripting::rust_analyzer::language::script_language_models::ScriptDefinitionLocation;
use crate::scripting::rust_analyzer::language::script_language_position::ScriptLanguageSpan;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptSignatureParameter {
    pub label: String,
    pub documentation: Option<String>,
}

impl ScriptSignatureParameter {
    pub fn new(label: String, documentation: Option<String>) -> Self {
        Self {
            label,
            documentation,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptSignatureInformation {
    pub label: String,
    pub documentation: Option<String>,
    pub parameters: Vec<ScriptSignatureParameter>,
}

impl ScriptSignatureInformation {
    pub fn new(
        label: String,
        documentation: Option<String>,
        parameters: Vec<ScriptSignatureParameter>,
    ) -> Self {
        Self {
            label,
            documentation,
            parameters,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptSignatureHelp {
    pub signatures: Vec<ScriptSignatureInformation>,
    pub active_signature: i64,
    pub active_parameter: Option<i64>,
}

impl ScriptSignatureHelp {
    pub fn new(
        signatures: Vec<ScriptSignatureInformation>,
        active_signature: i64,
        active_parameter: Option<i64>,
    ) -> Self {
        Self {
            signatures,
            active_signature,
            active_parameter,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptDocumentSymbol {
    pub name: String,
    pub detail: Option<String>,
    pub kind: i64,
    pub range: ScriptLanguageSpan,
    pub selection_range: ScriptLanguageSpan,
    pub children: Vec<ScriptDocumentSymbol>,
}

impl ScriptDocumentSymbol {
    pub fn new(
        name: String,
        detail: Option<String>,
        kind: i64,
        range: ScriptLanguageSpan,
        selection_range: ScriptLanguageSpan,
        children: Vec<ScriptDocumentSymbol>,
    ) -> Self {
        Self {
            name,
            detail,
            kind,
            range,
            selection_range,
            children,
        }
    }
}

/// A declaration anywhere in the indexed workspace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptWorkspaceSymbol {
    pub name: String,
    pub kind: i64,
    pub container_name: Option<String>,
    pub location: ScriptDefinitionLocation,
}

impl ScriptWorkspaceSymbol {
    pub fn new(
        name: String,
        kind: i64,
        container_name: Option<String>,
        location: ScriptDefinitionLocation,
    ) -> Self {
        Self {
            name,
            kind,
            container_name,
            location,
        }
    }
}
