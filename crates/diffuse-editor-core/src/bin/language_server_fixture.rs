//! Ported from `Editor/Tests/Fixtures/LanguageServer/main.swift`.
//!
//! A scripted LSP peer for the language-service tests: it counts launches,
//! records opened document text, answers the queries those tests exercise and
//! can crash or stall on request.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::process::ExitCode;
use std::time::Duration;

use serde_json::{Value, json};

fn crash(status: i32) -> ! {
    let _ = std::io::stderr().write_all(b"fixture unexpected exit\n");
    std::process::exit(status);
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.iter().any(|argument| argument == "--help") {
        let _ = std::io::stdout().write_all(b"test language server\n");
        return ExitCode::SUCCESS;
    }

    let root = std::env::var("COVE_TEST_LSP_ROOT").unwrap_or_default();
    let mode = std::env::var("COVE_TEST_LSP_MODE").unwrap_or_else(|_| "normal".to_string());
    let root_file = |name: &str| std::path::Path::new(&root).join(name);

    let count_file = root_file("count");
    let count = std::fs::read_to_string(&count_file)
        .ok()
        .and_then(|text| text.trim().parse::<i64>().ok())
        .map_or(1, |previous| previous + 1);
    write_atomic(&count_file, count.to_string().as_bytes());

    let mut opened = OpenOptions::new()
        .create(true)
        .append(true)
        .open(root_file("opened.jsonl"))
        .ok();

    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout();
    let mut buffer: Vec<u8> = Vec::new();

    loop {
        let mut length = 0usize;
        loop {
            let Some(header) = read_line(&mut stdin, &mut buffer) else {
                return ExitCode::SUCCESS;
            };
            if header.is_empty() {
                break;
            }
            let text = String::from_utf8_lossy(&header).to_lowercase();
            if let Some(value) = text.strip_prefix("content-length:") {
                length = value.trim().parse::<usize>().unwrap_or(0);
            }
        }
        let mut body = Vec::with_capacity(length);
        while body.len() < length {
            let Some(byte) = read_byte(&mut stdin, &mut buffer) else {
                return ExitCode::SUCCESS;
            };
            body.push(byte);
        }
        let message: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        let method = message.get("method").and_then(Value::as_str);

        if method == Some("test/crash")
            || (method == Some("textDocument/hover")
                && count == 1
                && ["crash-first-hover", "environment-first-connection"].contains(&mode.as_str()))
        {
            crash(31);
        }
        if method == Some("textDocument/didOpen") {
            let document = message
                .get("params")
                .and_then(|params| params.get("textDocument"));
            let text = document
                .and_then(|document| document.get("text"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if let Some(handle) = opened.as_mut()
                && let Ok(encoded) = serde_json::to_vec(&Value::String(text.to_string()))
            {
                let _ = handle.write_all(&encoded);
                let _ = handle.write_all(b"\n");
            }
            if mode == "crash-after-open" {
                std::thread::spawn(|| {
                    std::thread::sleep(Duration::from_millis(150));
                    std::process::exit(32);
                });
            }
            if mode == "environment-first-connection" {
                let diagnostics = if count == 1 {
                    json!([{
                        "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                        "severity": 1,
                        "message": "Loading the standard library failed",
                    }])
                } else {
                    json!([])
                };
                if count == 1 {
                    send(
                        &mut stdout,
                        &json!({
                            "jsonrpc": "2.0",
                            "method": "window/logMessage",
                            "params": {"type": 1, "message": "Loading the standard library failed"},
                        }),
                        false,
                    );
                }
                send(
                    &mut stdout,
                    &json!({
                        "jsonrpc": "2.0",
                        "method": "textDocument/publishDiagnostics",
                        "params": {
                            "uri": document
                                .and_then(|document| document.get("uri"))
                                .and_then(Value::as_str)
                                .unwrap_or(""),
                            "version": 1,
                            "diagnostics": diagnostics,
                        },
                    }),
                    false,
                );
            }
        }
        if method == Some("exit") {
            return ExitCode::SUCCESS;
        }
        if let Some(id) = message.get("id") {
            let mut result = Value::Null;
            match method {
                Some("initialize") => {
                    if mode == "slow-initialize" {
                        let _ = File::create(root_file("initializing"));
                        std::thread::sleep(Duration::from_secs(5));
                    }
                    result = json!({"capabilities": {}});
                }
                Some("textDocument/hover") => {
                    result = json!({"contents": {"kind": "markdown", "value": "recovered symbol"}});
                }
                Some("textDocument/documentSymbol") => {
                    result = json!([{
                        "name": "value",
                        "kind": 13,
                        "range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 9}},
                    }]);
                }
                Some("textDocument/formatting") => result = json!([]),
                Some("textDocument/completion") => {
                    result = json!({"items": [], "isIncomplete": false});
                }
                Some("test/burst") => {
                    for index in 0..200 {
                        send(
                            &mut stdout,
                            &json!({
                                "jsonrpc": "2.0",
                                "method": "test/notification",
                                "params": index,
                            }),
                            true,
                        );
                    }
                    result = json!(200);
                }
                Some("test/large") => {
                    result = Value::String("Swift 🥭\n".repeat(80_000));
                }
                _ => {}
            }
            send(
                &mut stdout,
                &json!({"jsonrpc": "2.0", "id": id, "result": result}),
                false,
            );
        }
    }
}

fn write_atomic(path: &std::path::Path, bytes: &[u8]) {
    let _ = cove_system::files::atomic_write(path, bytes, cove_system::files::Access::Inherit);
}

fn read_byte(stdin: &mut impl Read, buffer: &mut Vec<u8>) -> Option<u8> {
    while buffer.is_empty() {
        let mut chunk = [0u8; 4096];
        let read = stdin.read(&mut chunk).ok()?;
        if read == 0 {
            return None;
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
    Some(buffer.remove(0))
}

fn read_line(stdin: &mut impl Read, buffer: &mut Vec<u8>) -> Option<Vec<u8>> {
    let mut line = Vec::new();
    while let Some(byte) = read_byte(stdin, buffer) {
        if byte == b'\n' {
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Some(line);
        }
        line.push(byte);
    }
    None
}

fn send(stdout: &mut impl Write, message: &Value, fragmented: bool) {
    let Ok(body) = serde_json::to_vec(message) else {
        return;
    };
    let header = format!("Content-Length: {}\r\n\r\n", body.len());
    if fragmented {
        for byte in header.as_bytes().iter().chain(body.iter()) {
            let _ = stdout.write_all(&[*byte]);
            let _ = stdout.flush();
        }
    } else {
        let mut packet = header.into_bytes();
        packet.extend_from_slice(&body);
        let _ = stdout.write_all(&packet);
        let _ = stdout.flush();
    }
}
