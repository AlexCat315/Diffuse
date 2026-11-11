//! Translation of
//! Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/EditingReplies.swift.

use std::collections::BTreeMap;

use serde_json::Value;

use super::editing::{
    ScriptCodeAction, ScriptDocumentEdit, ScriptLanguageEditError, ScriptRenamePreparation,
    ScriptSemanticContext, ScriptWorkspaceEdit,
};
use super::script_language_models::ScriptCompletionTextEdit;
use super::script_language_protocol::ScriptLanguageReplies;

pub struct ScriptEditingReplies;

impl ScriptEditingReplies {
    pub fn workspace_edit(
        data: Option<&[u8]>,
        context: &ScriptSemanticContext,
    ) -> Result<ScriptWorkspaceEdit, ScriptLanguageEditError> {
        let Some(data) = data else {
            return Ok(ScriptWorkspaceEdit::new(Vec::new()));
        };
        let value: Value =
            serde_json::from_slice(data).map_err(|_| ScriptLanguageEditError::MalformedReply)?;
        if value.is_null() {
            return Ok(ScriptWorkspaceEdit::new(Vec::new()));
        }
        let object = value
            .as_object()
            .ok_or(ScriptLanguageEditError::MalformedReply)?;
        let mut documents: BTreeMap<String, ScriptDocumentEdit> = BTreeMap::new();

        fn append(
            documents: &mut BTreeMap<String, ScriptDocumentEdit>,
            context: &ScriptSemanticContext,
            uri: &str,
            version: Option<i64>,
            edits: Option<&Value>,
        ) -> Result<(), ScriptLanguageEditError> {
            let document = context
                .document(uri)
                .ok_or_else(|| ScriptLanguageEditError::ExternalDocument(uri.to_string()))?;
            if let Some(version) = version
                && version != document.version
            {
                return Err(ScriptLanguageEditError::StaleDocument(
                    document.script_id.clone(),
                ));
            }
            let parsed = ScriptEditingReplies::text_edits(edits)?;
            let entry = documents
                .entry(document.script_id.clone())
                .or_insert_with(|| {
                    ScriptDocumentEdit::new(
                        document.script_id.clone(),
                        document.revision,
                        Vec::new(),
                    )
                });
            entry.edits.extend(parsed);
            Ok(())
        }

        if let Some(changes) = object.get("changes") {
            let changes = changes
                .as_object()
                .ok_or(ScriptLanguageEditError::MalformedReply)?;
            for (uri, edits) in changes {
                append(&mut documents, context, uri, None, Some(edits))?;
            }
        }
        if let Some(changes) = object.get("documentChanges") {
            let changes = changes
                .as_array()
                .ok_or(ScriptLanguageEditError::MalformedReply)?;
            for change in changes {
                if change.get("kind").is_some() {
                    return Err(ScriptLanguageEditError::UnsupportedResourceOperation);
                }
                let document = change
                    .get("textDocument")
                    .ok_or(ScriptLanguageEditError::MalformedReply)?;
                let uri = document
                    .get("uri")
                    .and_then(Value::as_str)
                    .ok_or(ScriptLanguageEditError::MalformedReply)?;
                append(
                    &mut documents,
                    context,
                    uri,
                    document.get("version").and_then(Value::as_i64),
                    change.get("edits"),
                )?;
            }
        }
        Ok(ScriptWorkspaceEdit::new(documents.into_values().collect()))
    }

    pub fn text_edits(
        value: Option<&Value>,
    ) -> Result<Vec<ScriptCompletionTextEdit>, ScriptLanguageEditError> {
        let edits = value
            .and_then(Value::as_array)
            .ok_or(ScriptLanguageEditError::MalformedReply)?;
        edits
            .iter()
            .map(|edit| {
                let range = ScriptLanguageReplies::parse_span(edit.get("range"))
                    .ok_or(ScriptLanguageEditError::MalformedReply)?;
                let text = edit
                    .get("newText")
                    .and_then(Value::as_str)
                    .ok_or(ScriptLanguageEditError::MalformedReply)?;
                Ok(ScriptCompletionTextEdit::new(range, text.to_string()))
            })
            .collect()
    }

    pub fn code_actions(
        data: Option<&[u8]>,
        context: &ScriptSemanticContext,
    ) -> Result<Vec<ScriptCodeAction>, ScriptLanguageEditError> {
        let Some(data) = data else {
            return Ok(Vec::new());
        };
        let value: Value =
            serde_json::from_slice(data).map_err(|_| ScriptLanguageEditError::MalformedReply)?;
        if value.is_null() {
            return Ok(Vec::new());
        }
        let objects = value
            .as_array()
            .ok_or(ScriptLanguageEditError::MalformedReply)?;
        objects
            .iter()
            .map(|object| Self::code_action(object, context))
            .collect()
    }

    pub fn code_action(
        object: &Value,
        context: &ScriptSemanticContext,
    ) -> Result<ScriptCodeAction, ScriptLanguageEditError> {
        let title = object
            .get("title")
            .and_then(Value::as_str)
            .ok_or(ScriptLanguageEditError::MalformedReply)?
            .to_string();
        let mut disabled = object
            .get("disabled")
            .and_then(|disabled| disabled.get("reason"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if object.get("command").is_some() {
            disabled = Some(ScriptLanguageEditError::UnsupportedCommand.to_string());
        }
        let edit = match object.get("edit") {
            Some(edit) => {
                let bytes = serde_json::to_vec(edit)
                    .map_err(|_| ScriptLanguageEditError::MalformedReply)?;
                Some(Self::workspace_edit(Some(&bytes), context)?)
            }
            None => None,
        };
        let resolution = match object.get("data") {
            Some(_) => serde_json::to_vec(object).ok(),
            None => None,
        };
        let is_preferred = object
            .get("isPreferred")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let kind = object
            .get("kind")
            .and_then(Value::as_str)
            .map(str::to_string);
        if edit.is_none() && resolution.is_none() && disabled.is_none() {
            disabled = Some("This action does not provide an applicable edit.".to_string());
        }
        Ok(ScriptCodeAction::new(
            title,
            kind,
            is_preferred,
            disabled,
            edit,
            resolution,
            context.clone(),
        ))
    }

    pub fn rename_preparation(data: Option<&[u8]>) -> Option<ScriptRenamePreparation> {
        let value: Value = serde_json::from_slice(data?).ok()?;
        let range = ScriptLanguageReplies::parse_span(value.get("range"))
            .or_else(|| ScriptLanguageReplies::parse_span(Some(&value)))?;
        Some(ScriptRenamePreparation::new(
            range,
            value
                .get("placeholder")
                .and_then(Value::as_str)
                .map(str::to_string),
        ))
    }
}
