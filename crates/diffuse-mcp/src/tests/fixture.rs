//! Loopback editor fixture and stdout capture used by the MCP tests.

use std::io::{self, BufRead, BufReader, Write};
use std::net::{SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::Value;

/// Responder receives one request line (newline stripped) and returns the raw
/// bytes written back, so tests control newlines and malformed payloads.
type Responder = dyn Fn(&[u8]) -> Vec<u8> + Send + Sync + 'static;

/// Accepts one request line per connection on a free loopback port, records it
/// and replies with the responder's bytes.
pub struct MockEditor {
    address: SocketAddrV4,
    requests: Arc<Mutex<Vec<Vec<u8>>>>,
    stopped: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl MockEditor {
    pub fn start<F>(responder: F) -> Self
    where
        F: Fn(&[u8]) -> Vec<u8> + Send + Sync + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock editor");
        let address = match listener.local_addr().expect("mock editor address") {
            std::net::SocketAddr::V4(address) => address,
            std::net::SocketAddr::V6(_) => panic!("mock editor must bind IPv4"),
        };
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stopped = Arc::new(AtomicBool::new(false));
        let thread_requests = Arc::clone(&requests);
        let thread_stopped = Arc::clone(&stopped);
        let responder: Box<Responder> = Box::new(responder);
        let thread = std::thread::spawn(move || {
            while !thread_stopped.load(Ordering::SeqCst) {
                let Ok((stream, _)) = listener.accept() else {
                    return;
                };
                if thread_stopped.load(Ordering::SeqCst) {
                    return;
                }
                serve(stream, &*responder, &thread_requests);
            }
        });
        Self {
            address,
            requests,
            stopped,
            thread: Some(thread),
        }
    }

    pub fn port(&self) -> u16 {
        self.address.port()
    }

    /// Raw request lines in arrival order, including the trailing newline.
    pub fn requests(&self) -> Vec<Vec<u8>> {
        self.requests
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn request(&self, index: usize) -> Vec<u8> {
        let requests = self.requests();
        requests
            .get(index)
            .unwrap_or_else(|| panic!("request {index} was recorded"))
            .clone()
    }

    pub fn request_json(&self, index: usize) -> Value {
        let raw = self.request(index);
        serde_json::from_slice(trim_newline(&raw)).expect("editor request is JSON")
    }
}

impl Drop for MockEditor {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        // Wake the blocked accept so the thread observes `stopped`.
        let _ = TcpStream::connect(self.address);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn serve(mut stream: TcpStream, responder: &Responder, requests: &Mutex<Vec<Vec<u8>>>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let Ok(reader) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    match reader.read_until(b'\n', &mut line) {
        Ok(0) | Err(_) => return,
        Ok(_) => {}
    }
    requests
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .push(line.clone());
    let response = responder(trim_newline(&line));
    let _ = stream.write_all(&response);
    let _ = stream.flush();
}

fn trim_newline(raw: &[u8]) -> &[u8] {
    raw.strip_suffix(b"\n").unwrap_or(raw)
}

/// Serializes `value` plus the protocol's response newline.
pub fn json_line(value: &Value) -> Vec<u8> {
    let mut line = serde_json::to_vec(value).expect("serialize mock response");
    line.push(b'\n');
    line
}

/// Captures everything a `LineWriter` emits so notifications can be inspected.
#[derive(Clone, Default)]
pub struct CapturedWriter {
    bytes: Arc<Mutex<Vec<u8>>>,
}

impl CapturedWriter {
    pub fn lines(&self) -> Vec<String> {
        let bytes = self
            .bytes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        String::from_utf8_lossy(&bytes)
            .lines()
            .map(str::to_string)
            .collect()
    }
}

impl Write for CapturedWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.bytes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
