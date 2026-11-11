//! Translation of
//! Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/ScriptLanguageProtocol.swift
//! (MIGRATION.md §4 d1: the payload shapes are rust-analyzer's LSP messages).
//!
//! Builds request payloads and decodes replies into the model types the editor
//! consumes. The protocol permits several shapes per request (arrays vs objects,
//! legacy `MarkedString` vs `MarkupContent`, `CompletionItem[]` vs
//! `CompletionList`). Everything is optional: a partially understood reply
//! degrades to "no result" instead of surfacing as an error over a hover.

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_lsp::byte_stream::LspNotification;
use serde_json::{Value, json};

use super::script_language_models::{
    ScriptCompletionItem, ScriptCompletionItemKind, ScriptCompletionResult,
    ScriptCompletionTextEdit, ScriptDefinitionLocation, ScriptDiagnosticRelation,
    ScriptDiagnosticSeverity, ScriptDiagnosticTag, ScriptHoverResult, ScriptLanguageDiagnostic,
    ScriptMarkupKind,
};
use super::script_language_position::{
    ScriptLanguagePosition, ScriptLanguageSpan, ScriptSourceCoordinates,
};
use super::script_markdown_text::ScriptMarkdownText;

pub struct ScriptLanguageQueries;

impl ScriptLanguageQueries {
    pub const METHOD_HOVER: &'static str = "textDocument/hover";
    pub const METHOD_COMPLETION: &'static str = "textDocument/completion";
    pub const METHOD_DEFINITION: &'static str = "textDocument/definition";

    pub fn did_open(
        uri: &str,
        text: &str,
        version: i64,
        language_id: &str,
    ) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(&json!({
            "textDocument": {
                "uri": uri,
                "languageId": language_id,
                "version": version,
                "text": text,
            },
        }))
    }

    pub fn did_close(uri: &str) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(&json!({ "textDocument": { "uri": uri } }))
    }

    pub fn did_change(
        uri: &str,
        previous: &TextBuffer,
        current: &TextBuffer,
        version: i64,
    ) -> serde_json::Result<Option<Vec<u8>>> {
        let Some(delta) = current.edit_delta(previous) else {
            return Ok(None);
        };
        let start =
            ScriptSourceCoordinates::position_at_utf8_offset(previous, delta.start_utf8_offset);
        let end =
            ScriptSourceCoordinates::position_at_utf8_offset(previous, delta.old_end_utf8_offset);
        serde_json::to_vec(&json!({
            "textDocument": { "uri": uri, "version": version },
            "contentChanges": [{
                "range": {
                    "start": { "line": start.line, "character": start.character },
                    "end": { "line": end.line, "character": end.character },
                },
                "text": delta.new_text,
            }],
        }))
        .map(Some)
    }

    pub fn hover(uri: &str, at: ScriptLanguagePosition) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(&document_location_params(uri, at))
    }

    pub fn definition(uri: &str, at: ScriptLanguagePosition) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(&document_location_params(uri, at))
    }

    pub fn completion(
        uri: &str,
        at: ScriptLanguagePosition,
        trigger: CompletionTrigger,
        trigger_character: Option<&str>,
    ) -> serde_json::Result<Vec<u8>> {
        let mut params = document_location_params(uri, at);
        let mut context = json!({ "triggerKind": trigger.raw_value() });
        if let Some(trigger_character) = trigger_character {
            context["triggerCharacter"] = Value::String(trigger_character.to_string());
        }
        params["context"] = context;
        serde_json::to_vec(&params)
    }

    /// `completion(uri:at:trigger:triggerCharacter:)` with Swift's defaults.
    pub fn completion_default(
        uri: &str,
        at: ScriptLanguagePosition,
    ) -> serde_json::Result<Vec<u8>> {
        Self::completion(uri, at, CompletionTrigger::Invoked, None)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompletionTrigger {
    Invoked,
    TriggerCharacter,
    Incomplete,
}

impl CompletionTrigger {
    pub const fn raw_value(self) -> i64 {
        match self {
            CompletionTrigger::Invoked => 1,
            CompletionTrigger::TriggerCharacter => 2,
            CompletionTrigger::Incomplete => 3,
        }
    }
}

fn document_location_params(uri: &str, position: ScriptLanguagePosition) -> Value {
    json!({
        "textDocument": { "uri": uri },
        "position": { "line": position.line, "character": position.character },
    })
}

pub struct ScriptLanguageReplies;

impl ScriptLanguageReplies {
    // MARK: Diagnostics

    pub fn parse_diagnostics(
        notification: &LspNotification,
    ) -> Option<(String, Option<i64>, Vec<ScriptLanguageDiagnostic>)> {
        if notification.method != "textDocument/publishDiagnostics" {
            return None;
        }
        let params: Value = serde_json::from_slice(&notification.params).ok()?;
        let uri = params.get("uri")?.as_str()?.to_string();
        let diagnostics = params.get("diagnostics")?.as_array()?;
        let version = params.get("version").and_then(Value::as_i64);
        let parsed = diagnostics
            .iter()
            .filter_map(Self::parse_diagnostic)
            .collect();
        Some((uri, version, parsed))
    }

    pub fn parse_diagnostic(object: &Value) -> Option<ScriptLanguageDiagnostic> {
        let span = Self::parse_span(object.get("range"))?;
        let message = object.get("message")?.as_str()?.to_string();
        let severity_value = object
            .get("severity")
            .and_then(Value::as_i64)
            .unwrap_or(ScriptDiagnosticSeverity::Error.raw_value());
        let severity = ScriptDiagnosticSeverity::from_raw_value(severity_value)?;
        let code = match object.get("code") {
            Some(Value::String(value)) => Some(value.clone()),
            Some(Value::Number(value)) => Some(value.to_string()),
            _ => None,
        };
        let mut diagnostic = ScriptLanguageDiagnostic::new(
            severity,
            span.start.line,
            span.start.character,
            span.end.line,
            span.end.character,
            message,
            code,
        );
        diagnostic.tags = object
            .get("tags")
            .and_then(Value::as_array)
            .map(|tags| {
                tags.iter()
                    .filter_map(Value::as_i64)
                    .filter_map(ScriptDiagnosticTag::from_raw_value)
                    .collect()
            })
            .unwrap_or_default();
        diagnostic.related = object
            .get("relatedInformation")
            .and_then(Value::as_array)
            .map(|information| {
                information
                    .iter()
                    .take(32)
                    .filter_map(|information| {
                        let message = information.get("message")?.as_str()?.to_string();
                        let location = information.get("location")?;
                        let uri = location.get("uri")?.as_str()?.to_string();
                        let span = Self::parse_span(location.get("range"))?;
                        Some(ScriptDiagnosticRelation {
                            message,
                            location: ScriptDefinitionLocation::new(uri, None, span),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Some(diagnostic)
    }

    // MARK: Hover

    pub fn parse_hover(data: Option<&[u8]>) -> Option<ScriptHoverResult> {
        let object: Value = serde_json::from_slice(data?).ok()?;
        let (text, kind) = Self::parse_markup(object.get("contents"))?;
        let span = Self::parse_span(object.get("range"));
        let plain_text = if kind == ScriptMarkupKind::Plaintext {
            text.clone()
        } else {
            ScriptMarkdownText::plain_summary(&text)
        };
        Some(ScriptHoverResult::new(text, kind, plain_text, span))
    }

    /// `MarkupContent`, `MarkedString`, or an array of either.
    pub fn parse_markup(any: Option<&Value>) -> Option<(String, ScriptMarkupKind)> {
        match any? {
            Value::String(string) => {
                if string.is_empty() {
                    None
                } else {
                    Some((string.clone(), ScriptMarkupKind::Plaintext))
                }
            }
            Value::Array(items) => {
                let parts: Vec<(String, ScriptMarkupKind)> = items
                    .iter()
                    .filter_map(|item| Self::parse_markup(Some(item)))
                    .collect();
                if parts.is_empty() {
                    return None;
                }
                let joined = parts
                    .iter()
                    .map(|(text, _)| text.as_str())
                    .collect::<Vec<_>>()
                    .join("\n\n");
                let kind = if parts
                    .iter()
                    .any(|(_, kind)| *kind == ScriptMarkupKind::Markdown)
                {
                    ScriptMarkupKind::Markdown
                } else {
                    ScriptMarkupKind::Plaintext
                };
                Some((joined, kind))
            }
            Value::Object(object) => {
                if let Some(value) = object.get("value").and_then(Value::as_str) {
                    let kind = if object.get("kind").and_then(Value::as_str) == Some("markdown") {
                        ScriptMarkupKind::Markdown
                    } else {
                        ScriptMarkupKind::Plaintext
                    };
                    return Some((value.to_string(), kind));
                }
                // Legacy `MarkedString`: { language, value }. The language tag
                // only matters for editors that switch highlighting mid-popup.
                object
                    .get("text")
                    .and_then(Value::as_str)
                    .map(|value| (value.to_string(), ScriptMarkupKind::Plaintext))
            }
            _ => None,
        }
    }

    // MARK: Completion

    pub fn parse_completion(data: Option<&[u8]>) -> ScriptCompletionResult {
        let Some(data) = data else {
            return ScriptCompletionResult::empty();
        };
        let Ok(value) = serde_json::from_slice::<Value>(data) else {
            return ScriptCompletionResult::empty();
        };
        let (items, is_incomplete) = match &value {
            Value::Object(object) => (
                object
                    .get("items")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
                object
                    .get("isIncomplete")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            ),
            Value::Array(array) => (array.clone(), false),
            _ => return ScriptCompletionResult::empty(),
        };
        ScriptCompletionResult::new(
            items
                .iter()
                .filter_map(Self::parse_completion_item)
                .collect(),
            is_incomplete,
        )
    }

    pub fn parse_completion_item(object: &Value) -> Option<ScriptCompletionItem> {
        let label = object.get("label")?.as_str()?.to_string();
        if label.is_empty() {
            return None;
        }
        let kind = ScriptCompletionItemKind::from_raw_value(
            object.get("kind").and_then(Value::as_i64).unwrap_or(0),
        );
        let (insert_text, replacement) = match object.get("textEdit") {
            Some(edit) => (
                edit.get("newText")
                    .and_then(Value::as_str)
                    .unwrap_or(&label)
                    .to_string(),
                Self::parse_span(edit.get("range"))
                    .or_else(|| Self::parse_span(edit.get("replace")))
                    .or_else(|| Self::parse_span(edit.get("insert"))),
            ),
            None => (
                object
                    .get("insertText")
                    .and_then(Value::as_str)
                    .unwrap_or(&label)
                    .to_string(),
                None,
            ),
        };
        let mut item = ScriptCompletionItem::new(
            label,
            kind,
            object
                .get("detail")
                .and_then(Value::as_str)
                .map(str::to_string),
            Self::parse_markup(object.get("documentation")).map(|(text, _)| text),
            insert_text,
            replacement,
            object
                .get("filterText")
                .and_then(Value::as_str)
                .map(str::to_string),
            object
                .get("sortText")
                .and_then(Value::as_str)
                .map(str::to_string),
        );
        item.uses_snippet = object.get("insertTextFormat").and_then(Value::as_i64) == Some(2);
        item.additional_edits = object
            .get("additionalTextEdits")
            .and_then(Value::as_array)
            .map(|edits| {
                edits
                    .iter()
                    .filter_map(|edit| {
                        let range = Self::parse_span(edit.get("range"))?;
                        let text = edit.get("newText")?.as_str()?.to_string();
                        Some(ScriptCompletionTextEdit::new(range, text))
                    })
                    .collect()
            })
            .unwrap_or_default();
        if object.get("data").is_some() && object.get("documentation").is_none() {
            item.resolution = serde_json::to_vec(object).ok();
        }
        Some(item)
    }

    // MARK: Definition

    pub fn parse_definition(data: Option<&[u8]>) -> Vec<ScriptDefinitionLocation> {
        let Some(data) = data else {
            return Vec::new();
        };
        let Ok(value) = serde_json::from_slice::<Value>(data) else {
            return Vec::new();
        };
        let candidates: Vec<&Value> = match &value {
            Value::Array(array) => array.iter().collect(),
            other => vec![other],
        };
        candidates
            .into_iter()
            .filter_map(|candidate| {
                let object = candidate.as_object()?;
                // Plain `Location` uses uri/range; `LocationLink` (3.14+) uses
                // the `target*` pair and may carry a different selection range.
                let uri = object
                    .get("uri")
                    .and_then(Value::as_str)
                    .or_else(|| object.get("targetUri").and_then(Value::as_str))?;
                let span = Self::parse_span(object.get("range"))
                    .or_else(|| Self::parse_span(object.get("targetSelectionRange")))
                    .or_else(|| Self::parse_span(object.get("targetRange")))?;
                Some(ScriptDefinitionLocation::new(uri.to_string(), None, span))
            })
            .collect()
    }

    // MARK: Shared

    pub fn parse_span(any: Option<&Value>) -> Option<ScriptLanguageSpan> {
        let object = any?.as_object()?;
        let start = object.get("start")?.as_object()?;
        let end = object.get("end")?.as_object()?;
        let start_line = start.get("line")?.as_u64()? as usize;
        let start_character = start.get("character")?.as_u64()? as usize;
        let end_line = end.get("line")?.as_u64()? as usize;
        let end_character = end.get("character")?.as_u64()? as usize;
        if end_line < start_line || (end_line == start_line && end_character < start_character) {
            return None;
        }
        Some(ScriptLanguageSpan::new(
            ScriptLanguagePosition::new(start_line, start_character),
            ScriptLanguagePosition::new(end_line, end_character),
        ))
    }
}
