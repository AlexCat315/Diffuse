//! Translation of
//! Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/AssistanceReplies.swift.

use serde_json::Value;

use super::assistance::{
    ScriptDocumentSymbol, ScriptSignatureHelp, ScriptSignatureInformation, ScriptSignatureParameter,
};
use super::script_language_position::{ScriptLanguagePosition, ScriptLanguageSpan};
use super::script_language_protocol::ScriptLanguageReplies;

pub struct ScriptAssistanceReplies;

impl ScriptAssistanceReplies {
    pub fn signatures(data: Option<&[u8]>) -> Option<ScriptSignatureHelp> {
        let object: Value = serde_json::from_slice(data?).ok()?;
        let candidates = object.get("signatures")?.as_array()?;
        let signatures: Vec<ScriptSignatureInformation> = candidates
            .iter()
            .filter_map(|candidate| {
                let label = candidate.get("label")?.as_str()?.to_string();
                let parameters: Vec<ScriptSignatureParameter> = candidate
                    .get("parameters")
                    .and_then(Value::as_array)
                    .map(|parameters| {
                        parameters
                            .iter()
                            .filter_map(|parameter| {
                                let label_value = parameter.get("label")?;
                                let parameter_label = match label_value {
                                    Value::String(text) => text.clone(),
                                    Value::Array(offsets) if offsets.len() == 2 => {
                                        let start = offsets[0].as_u64()? as usize;
                                        let end = offsets[1].as_u64()? as usize;
                                        slice_utf16(&label, start, end)?
                                    }
                                    _ => return None,
                                };
                                Some(ScriptSignatureParameter::new(
                                    parameter_label,
                                    ScriptLanguageReplies::parse_markup(
                                        parameter.get("documentation"),
                                    )
                                    .map(|(text, _)| text),
                                ))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Some(ScriptSignatureInformation::new(
                    label,
                    ScriptLanguageReplies::parse_markup(candidate.get("documentation"))
                        .map(|(text, _)| text),
                    parameters,
                ))
            })
            .collect();
        if signatures.is_empty() {
            return None;
        }
        let active_signature = object
            .get("activeSignature")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .clamp(0, signatures.len() as i64 - 1);
        let parameter = candidates
            .get(active_signature as usize)
            .and_then(|candidate| candidate.get("activeParameter"))
            .and_then(Value::as_i64)
            .or_else(|| object.get("activeParameter").and_then(Value::as_i64));
        Some(ScriptSignatureHelp::new(
            signatures,
            active_signature,
            parameter,
        ))
    }

    pub fn symbols(data: Option<&[u8]>) -> Vec<ScriptDocumentSymbol> {
        let Some(data) = data else {
            return Vec::new();
        };
        let Ok(value) = serde_json::from_slice::<Value>(data) else {
            return Vec::new();
        };
        let Some(values) = value.as_array() else {
            return Vec::new();
        };
        values.iter().filter_map(symbol).collect()
    }

    /// Accepts `SymbolInformation` and `WorkspaceSymbol`; the latter may name
    /// only a file, which then opens at its top.
    pub fn workspace_symbols(
        data: Option<&[u8]>,
        limit: usize,
    ) -> Vec<(String, i64, Option<String>, String, ScriptLanguageSpan)> {
        let Some(data) = data else {
            return Vec::new();
        };
        let Ok(value) = serde_json::from_slice::<Value>(data) else {
            return Vec::new();
        };
        let Some(values) = value.as_array() else {
            return Vec::new();
        };
        values
            .iter()
            .take(limit)
            .filter_map(|object| {
                let name = object.get("name")?.as_str()?.to_string();
                let kind = object.get("kind")?.as_i64()?;
                let location = object.get("location")?;
                let uri = location.get("uri")?.as_str()?.to_string();
                let span =
                    ScriptLanguageReplies::parse_span(location.get("range")).unwrap_or_else(|| {
                        ScriptLanguageSpan::new(
                            ScriptLanguagePosition::new(0, 0),
                            ScriptLanguagePosition::new(0, 0),
                        )
                    });
                Some((
                    name,
                    kind,
                    object
                        .get("containerName")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    uri,
                    span,
                ))
            })
            .collect()
    }
}

fn symbol(object: &Value) -> Option<ScriptDocumentSymbol> {
    let name = object.get("name")?.as_str()?.to_string();
    let kind = object.get("kind")?.as_i64()?;
    let range = ScriptLanguageReplies::parse_span(object.get("range")).or_else(|| {
        object
            .get("location")
            .and_then(|location| ScriptLanguageReplies::parse_span(location.get("range")))
    })?;
    let selection_range =
        ScriptLanguageReplies::parse_span(object.get("selectionRange")).unwrap_or(range);
    let children = object
        .get("children")
        .and_then(Value::as_array)
        .map(|children| children.iter().filter_map(symbol).collect())
        .unwrap_or_default();
    Some(ScriptDocumentSymbol::new(
        name,
        object
            .get("detail")
            .and_then(Value::as_str)
            .map(str::to_string),
        kind,
        range,
        selection_range,
        children,
    ))
}

/// `String.Index(utf16Offset:)` + `samePosition(in:)`: the offsets must land on
/// character boundaries, otherwise the parameter label is dropped.
fn slice_utf16(label: &str, start: usize, end: usize) -> Option<String> {
    if start > end {
        return None;
    }
    let units: Vec<u16> = label.encode_utf16().collect();
    let total = units.len();
    if start > total || end > total {
        return None;
    }
    let slice = String::from_utf16(&units[start..end]).ok()?;
    // `from_utf16` rejects a split surrogate pair, which is exactly Swift's
    // `samePosition(in:)` returning nil for a non-character-boundary offset.
    Some(slice)
}
