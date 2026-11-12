//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/SourceKitLSPTransportTests.swift`.

use diffuse_lsp::byte_stream::{LspDecoder, LspMessageFramer};
use diffuse_lsp::lsp::error::LspClientError;

/// Decodes split and concatenated Content-Length messages.
#[test]
fn decodes_partial_and_multiple_frames() {
    let first = br#"{"jsonrpc":"2.0","id":1,"result":{}}"#.to_vec();
    let second = br#"{"jsonrpc":"2.0","method":"initialized"}"#.to_vec();
    let mut combined = LspMessageFramer::frame(&first);
    combined.extend_from_slice(&LspMessageFramer::frame(&second));
    let mut decoder = LspDecoder::new();

    assert!(decoder.append(&combined[..7]).expect("partial").is_empty());
    let messages = decoder.append(&combined[7..]).expect("complete frames");
    assert_eq!(messages, vec![first, second]);
    assert!(decoder.buffer().is_empty());
}

/// Rejects frames without Content-Length.
#[test]
fn rejects_missing_content_length() {
    let mut decoder = LspDecoder::new();
    let error = decoder
        .append(b"Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}")
        .expect_err("missing content length");
    assert_eq!(
        error,
        LspClientError::ProtocolViolation("missing Content-Length header".to_string())
    );
}

/// Survives a body delivered one byte at a time.
#[test]
fn reassembles_byte_at_a_time() {
    let body = br#"{"jsonrpc":"2.0","id":7,"result":null}"#.to_vec();
    let framed = LspMessageFramer::frame(&body);
    let mut decoder = LspDecoder::new();

    let mut seen: Vec<Vec<u8>> = Vec::new();
    for byte in framed {
        seen.extend(decoder.append(&[byte]).expect("byte"));
    }
    assert_eq!(seen, vec![body]);
}

/// Round-trips a UTF-8 body through framing.
#[test]
fn preserves_utf8_payload() {
    let body = r#"{"value":"Δt 秒"}"#.as_bytes().to_vec();
    let mut decoder = LspDecoder::new();
    let framed = LspMessageFramer::frame(&body);
    assert_eq!(decoder.append(&framed).expect("frame"), vec![body]);
}
