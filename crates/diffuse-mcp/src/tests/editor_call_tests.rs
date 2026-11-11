use std::net::TcpListener;

use serde_json::json;

use super::fixture::{MockEditor, json_line};
use crate::{MAX_EDITOR_RESPONSE_BYTES, editor_call};

#[test]
fn editor_call_sends_one_json_line() {
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));
    let request = json!({ "action": "open_capability_session", "session_id": "session-1" });

    let response = editor_call(editor.port(), &request);

    assert_eq!(response, json!({ "ok": true }));
    let raw = editor.request(0);
    assert_eq!(raw.iter().filter(|&&byte| byte == b'\n').count(), 1);
    assert_eq!(raw.last(), Some(&b'\n'));
    assert_eq!(
        &raw[..raw.len() - 1],
        serde_json::to_vec(&request)
            .expect("request serializes")
            .as_slice()
    );
}

#[test]
fn editor_call_reads_only_the_first_response_line() {
    let editor = MockEditor::start(|_| {
        let mut bytes = json_line(&json!({ "ok": true, "value": 1 }));
        bytes.extend_from_slice(b"{\"ok\":false}");
        bytes
    });

    let response = editor_call(editor.port(), &json!({ "action": "probe" }));

    assert_eq!(response, json!({ "ok": true, "value": 1 }));
}

#[test]
fn editor_call_reports_editor_not_running() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind probe listener");
    let port = listener.local_addr().expect("probe address").port();
    drop(listener);

    let response = editor_call(port, &json!({ "action": "probe" }));

    assert_eq!(
        response,
        json!({
            "ok": false,
            "error": format!("Diffuse is not running (could not connect to localhost:{port})"),
        })
    );
}

#[test]
fn editor_call_rejects_invalid_json() {
    let editor = MockEditor::start(|_| b"not json\n".to_vec());

    let response = editor_call(editor.port(), &json!({ "action": "probe" }));

    assert_eq!(
        response,
        json!({ "ok": false, "error": "invalid response from editor" })
    );
}

#[test]
fn editor_call_rejects_non_object_json() {
    let editor = MockEditor::start(|_| b"[1, 2]\n".to_vec());

    let response = editor_call(editor.port(), &json!({ "action": "probe" }));

    assert_eq!(
        response,
        json!({ "ok": false, "error": "invalid response from editor" })
    );
}

#[test]
fn editor_call_requires_a_response_newline() {
    let editor = MockEditor::start(|_| b"{\"ok\":true}".to_vec());

    let response = editor_call(editor.port(), &json!({ "action": "probe" }));

    assert_eq!(
        response,
        json!({
            "ok": false,
            "error": "editor disconnected or response timed out",
        })
    );
}

#[test]
fn editor_call_rejects_responses_over_two_mib() {
    let editor = MockEditor::start(|_| vec![b' '; MAX_EDITOR_RESPONSE_BYTES + 1]);

    let response = editor_call(editor.port(), &json!({ "action": "probe" }));

    assert_eq!(
        response,
        json!({ "ok": false, "error": "editor response exceeds 2 MiB" })
    );
}
