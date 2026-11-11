//! `Editor/Sources/EditorCore/Scene/Adapter/Support/EditorSceneJSON.swift`.

/// Trims the commit text; an empty document commits as `{}`.
pub(crate) fn normalized_json_commit_text(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        "{}".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Whether `text` is a single well-formed JSON document. `serde_json` rejects
/// trailing content the way `JSONSerialization.jsonObject(with:)` does.
pub(crate) fn is_valid_json_document(text: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(text).is_ok()
}
