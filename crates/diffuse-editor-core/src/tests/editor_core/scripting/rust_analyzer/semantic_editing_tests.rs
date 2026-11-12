//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/SemanticEditingTests.swift`.

use std::collections::BTreeMap;

use crate::scripting::rust_analyzer::language::assistance_replies::ScriptAssistanceReplies;
use crate::scripting::rust_analyzer::language::details::{
    ScriptAnalysisHealth, ScriptLanguageSemanticEvidence, ScriptLanguageServiceDetails,
};
use crate::scripting::rust_analyzer::language::editing::{
    ScriptLanguageEditError, ScriptSemanticContext, ScriptSemanticDocument,
};
use crate::scripting::rust_analyzer::language::editing_replies::ScriptEditingReplies;
use crate::scripting::rust_analyzer::language::script_language_protocol::ScriptLanguageReplies;

const RANGE: &str = r#"{"start":{"line":0,"character":4},"end":{"line":0,"character":9}}"#;
const URI: &str = "file:///shadow/Script.swift";

fn context() -> ScriptSemanticContext {
    ScriptSemanticContext::new(BTreeMap::from([(
        ScriptSemanticContext::document_key(URI),
        ScriptSemanticDocument::new("script.one".to_string(), 42, 7),
    )]))
}

/// Workspace edits map known documents and retain source revisions.
#[test]
fn maps_workspace_edit() {
    let payload = format!(r#"{{"changes":{{"{URI}":[{{"range":{RANGE},"newText":"value😀"}}]}}}}"#);
    let edit = ScriptEditingReplies::workspace_edit(Some(payload.as_bytes()), &context())
        .expect("workspace edit");
    let document = edit.documents.first().expect("document");
    assert_eq!(document.script_id, "script.one");
    assert_eq!(document.source_revision, 42);
    assert_eq!(document.edits[0].text, "value😀");
    assert_eq!(document.edits[0].range.end.character, 9);
}

/// Canonical language-server paths map back to the same known document.
#[test]
fn canonical_document_paths() {
    let root = std::env::temp_dir().join(diffuse_kernel::codable::new_uuid());
    let original = root.join("Original");
    std::fs::create_dir_all(&original).expect("original");
    std::fs::write(original.join("Script.swift"), "let value = 1").expect("script");
    let original_uri = file_uri(&original.join("Script.swift"));

    #[cfg(unix)]
    let (returned_uri, linked) = {
        let linked = root.join("Linked");
        std::os::unix::fs::symlink(&original, &linked).expect("symlink");
        (file_uri(&linked.join("Script.swift")), Some(linked))
    };
    #[cfg(not(unix))]
    let (returned_uri, linked) = {
        let linked = original.clone();
        (
            file_uri(&linked.join("Script.swift")),
            None::<std::path::PathBuf>,
        )
    };

    let mut documents = BTreeMap::new();
    documents.insert(
        ScriptSemanticContext::document_key(&original_uri),
        ScriptSemanticDocument::new("script.one".to_string(), 42, 7),
    );
    let context = ScriptSemanticContext::new(documents);
    let payload =
        format!(r#"{{"changes":{{"{returned_uri}":[{{"range":{RANGE},"newText":"value"}}]}}}}"#);
    let edit = ScriptEditingReplies::workspace_edit(Some(payload.as_bytes()), &context)
        .expect("workspace edit");
    assert_eq!(
        edit.documents
            .first()
            .map(|document| document.script_id.as_str()),
        Some("script.one")
    );
    assert_eq!(
        context
            .document(&returned_uri)
            .map(|document| document.revision),
        Some(42)
    );
    if let Some(linked) = linked {
        let _ = linked;
    }
    std::fs::remove_dir_all(root).ok();
}

fn file_uri(path: &std::path::Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    if text.starts_with('/') {
        format!("file://{text}")
    } else {
        format!("file:///{text}")
    }
}

/// Versioned changes reject stale versions and unknown files atomically.
#[test]
fn rejects_unsafe_edits() {
    let stale = format!(
        r#"{{"documentChanges":[{{"textDocument":{{"uri":"{URI}","version":6}},"edits":[]}}]}}"#
    );
    assert_eq!(
        ScriptEditingReplies::workspace_edit(Some(stale.as_bytes()), &context()),
        Err(ScriptLanguageEditError::StaleDocument(
            "script.one".to_string()
        ))
    );

    let outside = br#"{"changes":{"file:///etc/secret.swift":[]}}"#;
    assert_eq!(
        ScriptEditingReplies::workspace_edit(Some(outside), &context()),
        Err(ScriptLanguageEditError::ExternalDocument(
            "file:///etc/secret.swift".to_string()
        ))
    );

    let resource =
        br#"{"documentChanges":[{"kind":"rename","oldUri":"file:///a","newUri":"file:///b"}]}"#;
    assert_eq!(
        ScriptEditingReplies::workspace_edit(Some(resource), &context()),
        Err(ScriptLanguageEditError::UnsupportedResourceOperation)
    );
}

/// Malformed ranges and text edits fail closed.
#[test]
fn rejects_malformed_edits() {
    let malformed = format!(
        r#"{{"changes":{{"{URI}":[{{"range":{{"start":{{"line":0,"character":9}},"end":{{"line":0,"character":4}}}},"newText":"x"}}]}}}}"#
    );
    assert_eq!(
        ScriptEditingReplies::workspace_edit(Some(malformed.as_bytes()), &context()),
        Err(ScriptLanguageEditError::MalformedReply)
    );
    assert!(
        ScriptLanguageReplies::parse_span(Some(&serde_json::json!({
            "start": {"line": -1, "character": 0},
            "end": {"line": 0, "character": 0},
        })))
        .is_none()
    );
}

/// Code actions preserve resolution tokens and reject implicit commands.
#[test]
fn action_resolution() {
    let payload = br#"[{"title":"Add type","kind":"quickfix","isPreferred":true,"data":{"refactor":1}},{"title":"Run command","command":{"command":"swift.mutate"}}]"#;
    let actions = ScriptEditingReplies::code_actions(Some(payload), &context()).expect("actions");
    assert_eq!(actions.len(), 2);
    assert!(actions[0].is_preferred);
    assert!(actions[0].needs_resolution());
    assert!(actions[0].resolution.is_some());
    assert_eq!(
        actions[1].disabled_reason.as_deref(),
        Some(
            ScriptLanguageEditError::UnsupportedCommand
                .error_description()
                .as_str()
        )
    );
    assert!(!actions[1].needs_resolution());
}

/// Signature help understands UTF-16 parameter offsets and active parameter.
#[test]
fn signature_offsets() {
    let payload = br#"{"signatures":[{"label":"foo(a: Int, b: String)","documentation":{"kind":"markdown","value":"Docs"},"parameters":[{"label":[4,10]},{"label":"b: String"}],"activeParameter":1}],"activeSignature":4,"activeParameter":0}"#;
    let result = ScriptAssistanceReplies::signatures(Some(payload)).expect("signatures");
    assert_eq!(result.active_signature, 0);
    assert_eq!(result.active_parameter, Some(1));
    assert_eq!(result.signatures[0].parameters[0].label, "a: Int");
    assert_eq!(result.signatures[0].documentation.as_deref(), Some("Docs"));
}

/// Document symbols retain hierarchy and precise selection ranges.
#[test]
fn symbol_hierarchy() {
    let payload = format!(
        r#"[{{"name":"Game","kind":23,"range":{RANGE},"selectionRange":{RANGE},"children":[{{"name":"update","kind":6,"range":{RANGE}}}]}}]"#
    );
    let result = ScriptAssistanceReplies::symbols(Some(payload.as_bytes()));
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].children[0].name, "update");
    assert_eq!(result[0].children[0].selection_range.start.character, 4);
}

/// Details retain a bounded independent log with monotonic identifiers.
#[test]
fn bounded_details() {
    let mut details =
        ScriptLanguageServiceDetails::new("/toolchain/usr/bin/sourcekit-lsp".to_string());
    for value in 0..350 {
        details.record_with_default(&format!("event {value}"));
    }
    assert_eq!(details.logs.len(), 300);
    assert_eq!(details.logs.first().map(|entry| entry.id), Some(51));
    assert_eq!(details.logs.last().map(|entry| entry.id), Some(350));
    assert_eq!(details.health, ScriptAnalysisHealth::Checking);
}

/// Syntax-only and empty results do not confirm semantic analysis.
#[test]
fn semantic_evidence() {
    let empty = b"[]";
    let completion = br#"{"items":[],"isIncomplete":false}"#;
    let symbol = format!(r#"[{{"name":"Game","kind":23,"range":{RANGE}}}]"#);
    assert!(!ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/documentSymbol",
        Some(symbol.as_bytes())
    ));
    assert!(!ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/formatting",
        Some(empty)
    ));
    assert!(!ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/codeAction",
        Some(empty)
    ));
    assert!(!ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/completion",
        Some(completion)
    ));
    assert!(!ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/definition",
        Some(empty)
    ));
    assert!(!ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/hover",
        Some(b"null")
    ));
    assert!(ScriptLanguageSemanticEvidence::confirms_analysis(
        "textDocument/hover",
        Some(br#"{"contents":{"kind":"plaintext","value":"String"}}"#)
    ));
}
