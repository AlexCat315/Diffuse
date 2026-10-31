//! Read side and framing layer for the Language Server Protocol base protocol.
//!
//! Every LSP message is `<headers>\r\n\r\n<body>` where `Content-Length` counts
//! body bytes. Pipe delivery is unreliable in both directions: data may split a
//! message across callbacks or deliver several messages at once, so the decoder
//! buffers until a frame completes. This type holds no process state, which keeps
//! it unit-testable without launching a language server.

use crate::lsp::error::LspClientError;

/// Maximum accepted header block size; larger suspect headers are rejected
/// instead of buffering unboundedly.
pub const MAXIMUM_HEADER_BYTES: usize = 16 * 1_024;
/// Maximum accepted message body size (32 MiB).
pub const MAXIMUM_BODY_BYTES: usize = 32 * 1_024 * 1_024;

const HEADER_TERMINATOR: [u8; 4] = [13, 10, 13, 10];

pub struct LspMessageFramer;

impl LspMessageFramer {
    pub const MAXIMUM_HEADER_BYTES: usize = MAXIMUM_HEADER_BYTES;
    pub const MAXIMUM_BODY_BYTES: usize = MAXIMUM_BODY_BYTES;

    /// Wraps a JSON body into a base-protocol frame ready to write to stdin.
    pub fn frame(body: &[u8]) -> Vec<u8> {
        let header = format!("Content-Length: {}\r\n\r\n", body.len());
        let mut result = header.into_bytes();
        result.extend_from_slice(body);
        result
    }
}

/// Incremental decoder that yields every fully framed body.
#[derive(Default)]
pub struct LspDecoder {
    buffer: Vec<u8>,
}

impl LspDecoder {
    pub fn new() -> Self {
        LspDecoder { buffer: Vec::new() }
    }

    pub fn buffer(&self) -> &[u8] {
        &self.buffer
    }

    /// Feeds newly available bytes and returns every fully framed body.
    pub fn append(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>, LspClientError> {
        self.buffer.extend_from_slice(data);
        let mut messages = Vec::new();

        loop {
            let Some(separator) = find_separator(&self.buffer) else {
                if self.buffer.len() > MAXIMUM_HEADER_BYTES {
                    return Err(LspClientError::ProtocolViolation(
                        "header exceeds size limit".to_string(),
                    ));
                }
                break;
            };

            if separator > MAXIMUM_HEADER_BYTES {
                return Err(LspClientError::ProtocolViolation(
                    "invalid header encoding".to_string(),
                ));
            }
            let header = match std::str::from_utf8(&self.buffer[..separator]) {
                Ok(header) if header.is_ascii() => header.to_string(),
                _ => {
                    return Err(LspClientError::ProtocolViolation(
                        "invalid header encoding".to_string(),
                    ));
                }
            };
            let Some(length) = content_length(&header) else {
                return Err(LspClientError::ProtocolViolation(
                    "missing Content-Length header".to_string(),
                ));
            };
            if length > MAXIMUM_BODY_BYTES {
                return Err(LspClientError::ProtocolViolation(
                    "message exceeds size limit".to_string(),
                ));
            }

            let body_start = separator + HEADER_TERMINATOR.len();
            if self.buffer.len() - body_start < length {
                break;
            }
            let body_end = body_start + length;
            messages.push(self.buffer[body_start..body_end].to_vec());
            self.buffer.drain(..body_end);
        }

        Ok(messages)
    }
}

fn find_separator(buffer: &[u8]) -> Option<usize> {
    buffer.windows(HEADER_TERMINATOR.len()).position(|window| window == HEADER_TERMINATOR)
}

/// Reads `Content-Length` from a header block, matching Swift's case-insensitive
/// lookup and its `>= 0` guard.
pub fn content_length(header: &str) -> Option<usize> {
    for line in header.split("\r\n") {
        let mut parts = line.splitn(2, ':');
        let name = match parts.next() {
            Some(name) => name,
            None => continue,
        };
        let Some(value) = parts.next() else {
            continue;
        };
        if !name.trim().eq_ignore_ascii_case("Content-Length") {
            continue;
        }
        if let Ok(length) = value.trim().parse::<i64>()
            && length >= 0
        {
            return Some(length as usize);
        }
    }
    None
}

/// A server-initiated message that has no matching outstanding request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LspNotification {
    pub method: String,
    pub params: Vec<u8>,
}

impl LspNotification {
    #[inline]
    pub fn new(method: impl Into<String>, params: Vec<u8>) -> Self {
        LspNotification { method: method.into(), params }
    }
}
