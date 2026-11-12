//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/ScriptLanguageReplyTests.swift`.

use diffuse_lsp::byte_stream::LspNotification;

use crate::scripting::rust_analyzer::language::script_language_models::{
    ScriptCompletionItemKind, ScriptDiagnosticSeverity, ScriptMarkupKind,
};
use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptLanguageSpan,
};
use crate::scripting::rust_analyzer::language::script_language_protocol::ScriptLanguageReplies;
use crate::scripting::rust_analyzer::language::script_markdown_text::ScriptMarkdownText;

// MARK: Hover

/// Decodes MarkupContent with a markdown declaration.
#[test]
fn decodes_markup_content() {
    let payload = br#"{"contents":{"kind":"markdown","value":"```swift\nvar deltaTime: Float\n```\nSeconds elapsed."},"range":{"start":{"line":3,"character":4},"end":{"line":3,"character":13}}}"#;
    let result = ScriptLanguageReplies::parse_hover(Some(payload)).expect("hover");
    assert_eq!(result.kind, ScriptMarkupKind::Markdown);
    assert!(result.plain_text.contains("var deltaTime: Float"));
    assert!(result.plain_text.contains("Seconds elapsed."));
    assert_eq!(
        result.span,
        Some(ScriptLanguageSpan::with_corners(3, 4, 3, 13))
    );
}

/// Decodes a legacy MarkedString payload.
#[test]
fn decodes_marked_string() {
    let payload = br#"{"contents":{"language":"swift","value":"func foo()"}}"#;
    let result = ScriptLanguageReplies::parse_hover(Some(payload)).expect("hover");
    assert_eq!(result.kind, ScriptMarkupKind::Plaintext);
    assert_eq!(result.plain_text, "func foo()");
}

/// Returns nil for a null hover result.
#[test]
fn returns_nil_for_empty_hover() {
    assert!(ScriptLanguageReplies::parse_hover(None).is_none());
    assert!(ScriptLanguageReplies::parse_hover(Some(b"null")).is_none());
}

/// Strips markdown decorations from the summary.
#[test]
fn strips_markdown() {
    let markdown = "### Declaration\n\n```swift\nstatic func clamp(_ v: Int) -> Int\n```\n\nClamps **v** to the [limit](https://example.com).\n\n- lo: lower bound";
    let summary = ScriptMarkdownText::plain_summary(markdown);
    assert!(summary.starts_with("static func clamp(_ v: Int) -> Int"));
    assert!(summary.contains("Clamps v to the limit"));
    assert!(!summary.contains("**"));
    assert!(!summary.contains("https://"));
    assert!(summary.contains("• lo: lower bound"));
    assert!(!summary.to_lowercase().contains("### declaration"));
}

// MARK: Completion

/// Decodes a CompletionList.
#[test]
fn decodes_completion_list() {
    let payload = br#"{"isIncomplete":true,"items":[{"label":"deltaTime","kind":5,"detail":"Float","insertText":"deltaTime","textEdit":{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}},"newText":"deltaTime"}}]}"#;
    let result = ScriptLanguageReplies::parse_completion(Some(payload));
    assert!(result.is_incomplete);
    assert_eq!(result.items.len(), 1);
    assert_eq!(result.items[0].kind, ScriptCompletionItemKind::Field);
    assert_eq!(
        result.items[0].replacement.expect("replacement").start,
        ScriptLanguagePosition::new(2, 4)
    );
}

/// Accepts a bare array of completion items.
#[test]
fn decodes_completion_array() {
    let payload = br#"[{"label":"onUpdate","kind":2}]"#;
    let result = ScriptLanguageReplies::parse_completion(Some(payload));
    assert_eq!(result.items.len(), 1);
    assert_eq!(result.items[0].insert_text, "onUpdate");
    assert_eq!(result.items[0].kind, ScriptCompletionItemKind::Method);
}

// MARK: Definition

/// Decodes Location and LocationLink shapes.
#[test]
fn decodes_definition_shapes() {
    let location = br#"{"uri":"file:///a.swift","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}}"#;
    let link = br#"[{"targetUri":"file:///b.swift","targetRange":{"start":{"line":9,"character":2},"end":{"line":9,"character":6}},"targetSelectionRange":{"start":{"line":9,"character":2},"end":{"line":9,"character":6}},"originSelectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":4}}}]"#;

    let single = ScriptLanguageReplies::parse_definition(Some(location));
    let multiple = ScriptLanguageReplies::parse_definition(Some(link));
    assert_eq!(single.len(), 1);
    assert_eq!(single[0].document_uri, "file:///a.swift");
    assert_eq!(single[0].span.start.line, 1);
    assert_eq!(multiple.len(), 1);
    assert_eq!(multiple[0].document_uri, "file:///b.swift");
}

// MARK: Diagnostics

/// Parses a publishDiagnostics notification.
#[test]
fn parses_diagnostics() {
    let params = serde_json::to_vec(&serde_json::json!({
        "uri": "file:///Script.swift",
        "version": 4,
        "diagnostics": [{
            "range": {"start": {"line": 2, "character": 1}, "end": {"line": 2, "character": 5}},
            "severity": 1,
            "code": "cannot-find-type",
            "message": "cannot find type 'Foo' in scope",
        }],
    }))
    .expect("params");
    let notification = LspNotification::new("textDocument/publishDiagnostics", params);
    let (uri, version, diagnostics) =
        ScriptLanguageReplies::parse_diagnostics(&notification).expect("published");
    assert_eq!(uri, "file:///Script.swift");
    assert_eq!(version, Some(4));
    assert_eq!(diagnostics.len(), 1);
    assert_eq!(diagnostics[0].severity, ScriptDiagnosticSeverity::Error);
    assert_eq!(diagnostics[0].code.as_deref(), Some("cannot-find-type"));
    assert_eq!(diagnostics[0].end_character, 5);
}

/// Ignores notifications for other methods.
#[test]
fn ignores_other_notifications() {
    let notification = LspNotification::new(
        "window/logMessage",
        serde_json::to_vec(&serde_json::json!({"message": "hi"})).expect("params"),
    );
    assert!(ScriptLanguageReplies::parse_diagnostics(&notification).is_none());
}
