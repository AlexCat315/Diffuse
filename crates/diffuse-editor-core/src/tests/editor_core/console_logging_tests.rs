//! Ported from `Editor/Tests/EditorCoreTests/ConsoleLoggingTests.swift`.

use std::sync::atomic::{AtomicU64, Ordering};

use cove_logging::{Level, LogEvent, LogQuery, LogSystem, LogValue};

use crate::application::diagnostics::subscriptions::EditorLogCapture;
use crate::state::assistant::editor_output_state::EditorOutputState;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleEntry, EditorConsoleSeverity};
use crate::state::editor_store::EditorStore;
use crate::state::workspace::editor_workbench_state::EditorOutputTab;

static NEXT_MARKER: AtomicU64 = AtomicU64::new(0);

/// Console records remain session data.
#[test]
fn console_records_remain_session_data() {
    let state = EditorOutputState {
        console_entries: vec![EditorConsoleEntry {
            id: 91,
            severity: EditorConsoleSeverity::Error,
            message: "temporary".to_string(),
            detail: None,
            target: None,
            next_step: None,
            record: None,
        }],
        next_console_entry_id: 92,
        ..EditorOutputState::default()
    };
    let encoded = serde_json::to_vec(&state).expect("encode");
    assert_eq!(String::from_utf8(encoded.clone()).expect("utf8"), "{}");
    let restored: EditorOutputState = serde_json::from_slice(&encoded).expect("decode");
    assert!(restored.console_entries.is_empty());
    assert_eq!(restored.next_console_entry_id, 1);
    assert_eq!(restored.output_tab, EditorOutputTab::Logs);
}

/// Domain console journal does not feed back and engine records are queued.
#[test]
fn domain_console_journal_does_not_feed_back_and_engine_records_are_queued() {
    let capture = EditorLogCapture::new();
    capture.take();
    let marker = format!(
        "marker-{}-{}-{}",
        std::process::id(),
        NEXT_MARKER.fetch_add(1, Ordering::Relaxed),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    );
    let store = EditorStore::new();
    store.dispatch(EditorAction::AppendConsoleMessage {
        message: marker.clone(),
        severity: EditorConsoleSeverity::Warning,
        detail: Some("details".to_string()),
        target: None,
        next_step: Some("retry".to_string()),
    });
    LogSystem::logger("com.cove.engine.test")
        .log(&LogEvent::new(Level::Warning, format!("engine-{marker}")));
    LogSystem::flush();
    let pending = capture.take();
    assert!(!pending.iter().any(|record| record.message == marker));
    assert!(
        pending
            .iter()
            .any(|record| record.message == format!("engine-{marker}"))
    );
    assert_eq!(
        store
            .state()
            .output
            .console_entries
            .iter()
            .filter(|entry| entry.message == marker)
            .count(),
        1
    );
    let snapshot = LogSystem::snapshot(LogQuery::default());
    assert!(snapshot.records.iter().any(|record| {
        record.message == marker
            && record.metadata.get("next_step") == Some(&LogValue::String("retry".to_string()))
    }));
    capture.stop();
}
