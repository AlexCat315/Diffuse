//! Translation of
//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/SemanticQueries.swift`
//! (MIGRATION.md §4 D1: the server is rust-analyzer and user scripts are Rust).
//!
//! Swift's `extension ScriptLanguageSupport` becomes a second inherent `impl`
//! on the support type. Every `async throws` method is a synchronous function
//! returning `Result<_, ScriptLanguageSupportFailure>` (§5.5); LSP method names
//! such as `textDocument/references` are unchanged.

use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::scripting::rust_analyzer::language::assistance::{
    ScriptDocumentSymbol, ScriptSignatureHelp,
};
use crate::scripting::rust_analyzer::language::assistance_replies::ScriptAssistanceReplies;
use crate::scripting::rust_analyzer::language::editing::{
    ScriptCodeAction, ScriptDocumentEdit, ScriptLanguageEditError, ScriptRenamePreparation,
    ScriptWorkspaceEdit,
};
use crate::scripting::rust_analyzer::language::editing_replies::ScriptEditingReplies;
use crate::scripting::rust_analyzer::language::inheritance_clause::ScriptInheritanceClause;
use crate::scripting::rust_analyzer::language::script_language_models::ScriptDefinitionLocation;
use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptLanguageSpan,
};
use crate::scripting::rust_analyzer::language::script_language_protocol::ScriptLanguageReplies;
use crate::scripting::script_language_support::{
    ScriptLanguageSupport, ScriptLanguageSupportFailure,
};

impl ScriptLanguageSupport {
    pub fn references(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, ScriptLanguageSupportFailure> {
        let mut extra = Map::new();
        extra.insert("context".to_string(), json!({ "includeDeclaration": true }));
        let response = self.semantic_request("textDocument/references", script_id, |uri| {
            Self::location_parameters(uri, at, &extra)
        })?;
        let locations = ScriptLanguageReplies::parse_definition(response.payload.as_deref());
        Ok(locations
            .into_iter()
            .map(|location| {
                let script_id = response
                    .context
                    .document(&location.document_uri)
                    .map(|document| document.script_id.clone());
                ScriptDefinitionLocation::new(location.document_uri, script_id, location.span)
            })
            .collect())
    }

    /// Trait implementors of a requirement and overrides of a member.
    pub fn implementations(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, ScriptLanguageSupportFailure> {
        let no_extra = Map::new();
        let response = self.semantic_request("textDocument/implementation", script_id, |uri| {
            Self::location_parameters(uri, at, &no_extra)
        })?;
        let locations = ScriptLanguageReplies::parse_definition(response.payload.as_deref());
        Ok(locations
            .into_iter()
            .map(|location| {
                let script_id = response
                    .context
                    .document(&location.document_uri)
                    .map(|document| document.script_id.clone());
                ScriptDefinitionLocation::new(location.document_uri, script_id, location.span)
            })
            .collect())
    }

    /// Traits and supertypes of the type declared at `at`.
    /// Falls back to the declaration's trait/impl clause, resolved name by
    /// name, when the index has no hierarchy for types from compiled crates.
    pub fn supertypes(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, ScriptLanguageSupportFailure> {
        let hierarchy = self.type_hierarchy("typeHierarchy/supertypes", script_id, at)?;
        if !hierarchy.is_empty() {
            return Ok(hierarchy);
        }
        let Some(text) = self.current_text(script_id) else {
            return Ok(hierarchy);
        };
        let mut found = Vec::new();
        for name in ScriptInheritanceClause::type_positions(&text, at) {
            if let Some(location) = self.definition(script_id, name)?.into_iter().next() {
                found.push(location);
            }
        }
        Ok(found)
    }

    /// Types below a type in the hierarchy and implementors of its traits.
    pub fn subtypes(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, ScriptLanguageSupportFailure> {
        self.type_hierarchy("typeHierarchy/subtypes", script_id, at)
    }

    /// The request is two steps: prepare names the item, then a second request
    /// walks one level from it. Each item's selection range is its name.
    fn type_hierarchy(
        self: &Arc<Self>,
        method: &str,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, ScriptLanguageSupportFailure> {
        let no_extra = Map::new();
        let prepared =
            self.semantic_request("textDocument/prepareTypeHierarchy", script_id, |uri| {
                Self::location_parameters(uri, at, &no_extra)
            })?;
        let Some(data) = prepared.payload.as_deref() else {
            return Ok(Vec::new());
        };
        let value = parse_json_object(data)?;
        let Some(items) = value.as_array() else {
            return Ok(Vec::new());
        };
        let Some(item) = items.first() else {
            return Ok(Vec::new());
        };
        let mut params = Map::new();
        params.insert("item".to_string(), (*item).clone());
        let params = Value::Object(params);
        let payload = self.resolve_semantic_request(method, &params, &prepared.context)?;
        let Some(payload) = payload else {
            return Ok(Vec::new());
        };
        let related_value = parse_json_object(&payload)?;
        let Some(related) = related_value.as_array() else {
            return Ok(Vec::new());
        };
        Ok(related
            .iter()
            .filter_map(|item| {
                let uri = item.get("uri")?.as_str()?.to_string();
                let span = ScriptLanguageReplies::parse_span(
                    item.get("selectionRange").or_else(|| item.get("range")),
                )?;
                let script_id = prepared
                    .context
                    .document(&uri)
                    .map(|document| document.script_id.clone());
                Some(ScriptDefinitionLocation::new(uri, script_id, span))
            })
            .collect())
    }

    pub fn prepare_rename(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Option<ScriptRenamePreparation>, ScriptLanguageSupportFailure> {
        let no_extra = Map::new();
        let response = self.semantic_request("textDocument/prepareRename", script_id, |uri| {
            Self::location_parameters(uri, at, &no_extra)
        })?;
        Ok(ScriptEditingReplies::rename_preparation(
            response.payload.as_deref(),
        ))
    }

    pub fn rename(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
        new_name: &str,
    ) -> Result<ScriptWorkspaceEdit, ScriptLanguageSupportFailure> {
        let has_invalid_character = new_name.chars().any(|character| {
            matches!(
                character,
                '\n' | '\r' | '\u{000B}' | '\u{000C}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
            ) || character == '\0'
        });
        if new_name.trim().is_empty() || has_invalid_character {
            return Err(ScriptLanguageEditError::MalformedReply.into());
        }
        let mut extra = Map::new();
        extra.insert("newName".to_string(), Value::String(new_name.to_string()));
        let response = self.semantic_request("textDocument/rename", script_id, |uri| {
            Self::location_parameters(uri, at, &extra)
        })?;
        Ok(ScriptEditingReplies::workspace_edit(
            response.payload.as_deref(),
            &response.context,
        )?)
    }

    pub fn code_actions(
        self: &Arc<Self>,
        script_id: &str,
        range: ScriptLanguageSpan,
    ) -> Result<Vec<ScriptCodeAction>, ScriptLanguageSupportFailure> {
        let diagnostics = self.diagnostic_payloads(script_id);
        let response = self.semantic_request("textDocument/codeAction", script_id, |uri| {
            let diagnostics: Vec<Value> = diagnostics
                .iter()
                .filter_map(|data| serde_json::from_slice::<Value>(data.as_slice()).ok())
                .collect();
            Ok(json!({
                "textDocument": { "uri": uri },
                "range": Self::range_parameters(range),
                "context": {
                    "diagnostics": diagnostics,
                    "triggerKind": 1,
                },
            }))
        })?;
        Ok(ScriptEditingReplies::code_actions(
            response.payload.as_deref(),
            &response.context,
        )?)
    }

    pub fn resolve_code_action(
        self: &Arc<Self>,
        action: ScriptCodeAction,
    ) -> Result<ScriptCodeAction, ScriptLanguageSupportFailure> {
        if action.disabled_reason.is_some() {
            return Ok(action);
        }
        let Some(resolution) = action.resolution.clone() else {
            return Ok(action);
        };
        // Swift passed the stored `Data` as the JSON-RPC params directly; the
        // Rust client takes a structural `Value`, so the bytes are restored.
        let params = parse_json_object(&resolution)?;
        let payload =
            self.resolve_semantic_request("codeAction/resolve", &params, &action.context)?;
        let Some(payload) = payload else {
            return Err(ScriptLanguageEditError::MalformedReply.into());
        };
        let object = parse_json_object(&payload)?;
        if !object.is_object() {
            return Err(ScriptLanguageEditError::MalformedReply.into());
        }
        Ok(ScriptEditingReplies::code_action(&object, &action.context)?)
    }

    pub fn signature_help(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Option<ScriptSignatureHelp>, ScriptLanguageSupportFailure> {
        let no_extra = Map::new();
        let response = self.semantic_request("textDocument/signatureHelp", script_id, |uri| {
            Self::location_parameters(uri, at, &no_extra)
        })?;
        Ok(ScriptAssistanceReplies::signatures(
            response.payload.as_deref(),
        ))
    }

    /// Every place in the document that names the symbol at `at`.
    pub fn document_highlights(
        self: &Arc<Self>,
        script_id: &str,
        at: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptLanguageSpan>, ScriptLanguageSupportFailure> {
        let no_extra = Map::new();
        let response =
            self.semantic_request("textDocument/documentHighlight", script_id, |uri| {
                Self::location_parameters(uri, at, &no_extra)
            })?;
        let Some(data) = response.payload.as_deref() else {
            return Ok(Vec::new());
        };
        let value = parse_json_object(data)?;
        let Some(values) = value.as_array() else {
            return Ok(Vec::new());
        };
        Ok(values
            .iter()
            .take(1_000)
            .filter_map(|object| ScriptLanguageReplies::parse_span(object.get("range")))
            .collect())
    }

    pub fn document_symbols(
        self: &Arc<Self>,
        script_id: &str,
    ) -> Result<Vec<ScriptDocumentSymbol>, ScriptLanguageSupportFailure> {
        let response = self.semantic_request("textDocument/documentSymbol", script_id, |uri| {
            Ok(json!({ "textDocument": { "uri": uri } }))
        })?;
        Ok(ScriptAssistanceReplies::symbols(
            response.payload.as_deref(),
        ))
    }

    /// Formats the document, or only `range` when one is given.
    pub fn formatting(
        self: &Arc<Self>,
        script_id: &str,
        range: Option<ScriptLanguageSpan>,
        tab_size: usize,
        insert_spaces: bool,
    ) -> Result<ScriptWorkspaceEdit, ScriptLanguageSupportFailure> {
        let method = if range.is_none() {
            "textDocument/formatting"
        } else {
            "textDocument/rangeFormatting"
        };
        let response = self.semantic_request(method, script_id, |uri| {
            let mut parameters = Map::new();
            parameters.insert("textDocument".to_string(), json!({ "uri": uri }));
            parameters.insert(
                "options".to_string(),
                json!({
                    "tabSize": tab_size.clamp(1, 16),
                    "insertSpaces": insert_spaces,
                }),
            );
            if let Some(range) = range {
                parameters.insert("range".to_string(), Self::range_parameters(range));
            }
            Ok(Value::Object(parameters))
        })?;
        let document = response
            .context
            .documents
            .values()
            .find(|document| document.script_id.as_str() == script_id)
            .ok_or_else(|| ScriptLanguageEditError::StaleDocument(script_id.to_string()))?;
        let Some(payload) = response.payload.as_deref() else {
            return Ok(ScriptWorkspaceEdit::new(Vec::new()));
        };
        let value = parse_json_object(payload)?;
        if value.is_null() {
            return Ok(ScriptWorkspaceEdit::new(Vec::new()));
        }
        let edits = ScriptEditingReplies::text_edits(Some(&value))?;
        Ok(ScriptWorkspaceEdit::new(vec![ScriptDocumentEdit::new(
            script_id.to_string(),
            document.revision,
            edits,
        )]))
    }

    fn location_parameters(
        uri: &str,
        position: ScriptLanguagePosition,
        extra: &Map<String, Value>,
    ) -> serde_json::Result<Value> {
        let mut parameters = extra.clone();
        parameters.insert("textDocument".to_string(), json!({ "uri": uri }));
        parameters.insert(
            "position".to_string(),
            json!({ "line": position.line, "character": position.character }),
        );
        Ok(Value::Object(parameters))
    }

    fn range_parameters(range: ScriptLanguageSpan) -> Value {
        json!({
            "start": { "line": range.start.line, "character": range.start.character },
            "end": { "line": range.end.line, "character": range.end.character },
        })
    }
}

/// `JSONSerialization.jsonObject(with:options:[.fragmentsAllowed])`: serde_json
/// already accepts top-level fragments, so only the failure needs mapping onto
/// [`ScriptLanguageSupportFailure`].
fn parse_json_object(data: &[u8]) -> Result<Value, ScriptLanguageSupportFailure> {
    serde_json::from_slice(data)
        .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))
}
