//! Ported from `Engine/Tests/AIRuntimeTests/PluginSessionUpdateTests.swift`.

use diffuse_capability::contracts::exports::SessionApiFormat;

use crate::session::conversation_turn::{ConversationTurn, ConversationTurnKind};
use crate::session::session::Session;
use crate::session::session_config::SessionConfig;

/// `capability replacement preserves conversation and model configuration`
#[test]
fn keeps_conversation() {
    let session = Session::with_defaults(SessionConfig::new_with_defaults(
        "fixture",
        "fixture-model",
        "https://example.invalid",
        SessionApiFormat::Anthropic,
    ));
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "Keep this conversation".to_string(),
    )));
    session.replace_plugin_capabilities(None, None);
    let history = session.history_snapshot();
    assert_eq!(history.len(), 1);
    let turn = history.first().expect("history has one turn");
    let ConversationTurnKind::UserText(text) = &turn.kind else {
        panic!("lost user turn");
    };
    assert_eq!(text, "Keep this conversation");
    assert_eq!(session.config().model, "fixture-model");
}
