//! Ported from `Engine/Tests/AIRuntimeTests/CompletionTests.swift`.

use diffuse_capability::contracts::exports::SessionApiFormat;

use crate::session::session::Session;
use crate::tools::project_toolset::ProjectToolset;

#[test]
fn completion_text_reads_every_provider_format() {
    let anthropic = r#"{"content":[{"type":"text","text":"Hello "},{"type":"tool_use","id":"x"},{"type":"text","text":"world"}]}"#;
    assert_eq!(
        Session::completion_text(anthropic.as_bytes(), SessionApiFormat::Anthropic)
            .expect("Anthropic text blocks join"),
        "Hello world"
    );
    let chat = r#"{"choices":[{"message":{"role":"assistant","content":"Fix typo"}}]}"#;
    assert_eq!(
        Session::completion_text(chat.as_bytes(), SessionApiFormat::OpenAiCompatible)
            .expect("chat completions expose the message content"),
        "Fix typo"
    );
    let responses = r#"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#;
    assert_eq!(
        Session::completion_text(responses.as_bytes(), SessionApiFormat::OpenAiResponses)
            .expect("responses output_text blocks join"),
        "Done"
    );
    assert!(
        Session::completion_text(b"[]", SessionApiFormat::Anthropic).is_err(),
        "a top-level array is not a provider response"
    );
}

#[test]
fn version_control_tools_are_declared_for_the_agent() {
    for name in ["vcs_status", "vcs_diff", "vcs_log"] {
        assert_eq!(
            ProjectToolset::definition(name).map(|tool| tool.read_only),
            Some(true)
        );
    }
    assert_eq!(
        ProjectToolset::definition("vcs_commit").map(|tool| tool.read_only),
        Some(false)
    );
}
