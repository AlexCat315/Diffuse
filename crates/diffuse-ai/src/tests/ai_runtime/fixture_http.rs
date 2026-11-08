//! Loopback HTTP/1.1 fixture used by session tests.
//!
//! Swift injected `URLProtocol` subclasses into `URLSession`. `cove_http` has
//! no transport seam, so these tests serve real requests from a local socket
//! instead and inspect the recorded bodies.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// One canned HTTP reply: status line, extra headers and JSON body.
///
/// Retry tests need non-200 statuses and a `Retry-After` header, so the handler
/// returns this rather than bare bytes. `FixtureHttpServer::start` wraps a
/// bytes-only handler into a 200 reply for the common case.
pub struct FixtureResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl FixtureResponse {
    pub fn json(body: Vec<u8>) -> Self {
        FixtureResponse {
            status: 200,
            headers: Vec::new(),
            body,
        }
    }

    pub fn with_status(status: u16, body: Vec<u8>) -> Self {
        FixtureResponse {
            status,
            headers: Vec::new(),
            body,
        }
    }

    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }
}

/// Serves one response per connection on `127.0.0.1:0`.
///
/// `handler` receives the zero-based request index and the request body, and
/// returns the JSON bytes to send back with status 200.
pub struct FixtureHttpServer {
    base_url: String,
    address: SocketAddr,
    requests: Arc<Mutex<Vec<Vec<u8>>>>,
    stopped: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl FixtureHttpServer {
    pub fn start<F>(handler: F) -> Self
    where
        F: Fn(usize, &[u8]) -> Vec<u8> + Send + Sync + 'static,
    {
        Self::start_with(move |index, body| FixtureResponse::json(handler(index, body)))
    }

    /// Like [`start`](Self::start), but the handler chooses the status and headers.
    pub fn start_with<F>(handler: F) -> Self
    where
        F: Fn(usize, &[u8]) -> FixtureResponse + Send + Sync + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture listener");
        let address = listener.local_addr().expect("fixture listener address");
        listener
            .set_nonblocking(true)
            .expect("nonblocking fixture listener");
        let base_url = format!("http://127.0.0.1:{}", address.port());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stopped = Arc::new(AtomicBool::new(false));
        let thread_requests = Arc::clone(&requests);
        let thread_stopped = Arc::clone(&stopped);
        let thread = std::thread::spawn(move || {
            while !thread_stopped.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        serve_connection(stream, &handler, &thread_requests);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(_) => return,
                }
            }
        });
        Self {
            base_url,
            address,
            requests,
            stopped,
            thread: Some(thread),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Request bodies in arrival order.
    pub fn requests(&self) -> Vec<Vec<u8>> {
        match self.requests.lock() {
            Ok(requests) => requests.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    pub fn request_json(&self, index: usize) -> serde_json::Value {
        let requests = self.requests();
        serde_json::from_slice(&requests[index]).expect("fixture request is JSON")
    }
}

impl Drop for FixtureHttpServer {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        // Wake a listener blocked between polls so shutdown is immediate.
        let _ = TcpStream::connect(self.address);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn serve_connection<F>(mut stream: TcpStream, handler: &F, requests: &Mutex<Vec<Vec<u8>>>)
where
    F: Fn(usize, &[u8]) -> FixtureResponse,
{
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let Ok(mut reader) = stream.try_clone().map(BufReader::new) else {
        return;
    };
    let Some(head) = read_head(&mut reader) else {
        return;
    };
    let Some(body) = read_body(&head, &mut reader) else {
        let _ = stream.write_all(
            b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        return;
    };
    let index = {
        let mut recorded = match requests.lock() {
            Ok(recorded) => recorded,
            Err(poisoned) => poisoned.into_inner(),
        };
        let index = recorded.len();
        recorded.push(body.clone());
        index
    };
    let response = handler(index, &body);
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        response.status,
        reason_phrase(response.status),
        response.body.len()
    );
    for (name, value) in &response.headers {
        head.push_str(name);
        head.push_str(": ");
        head.push_str(value);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");
    let mut payload = head.into_bytes();
    payload.extend_from_slice(&response.body);
    let _ = stream.write_all(&payload);
    let _ = stream.flush();
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

fn read_head(reader: &mut BufReader<TcpStream>) -> Option<String> {
    let mut head = String::new();
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return None,
            Ok(_) => {
                let done = line == "\r\n" || line == "\n";
                head.push_str(&line);
                if done {
                    return Some(head);
                }
            }
            Err(_) => return None,
        }
    }
}

fn read_body(head: &str, reader: &mut BufReader<TcpStream>) -> Option<Vec<u8>> {
    let chunked = header(head, "transfer-encoding")
        .is_some_and(|value| value.eq_ignore_ascii_case("chunked"));
    if chunked {
        return read_chunked(reader);
    }
    let length = header(head, "content-length")
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(0);
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).ok()?;
    Some(body)
}

fn read_chunked(reader: &mut BufReader<TcpStream>) -> Option<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).ok()?;
        let size = usize::from_str_radix(line.trim().split(';').next()?.trim(), 16).ok()?;
        if size == 0 {
            let mut trailer = String::new();
            reader.read_line(&mut trailer).ok()?;
            return Some(body);
        }
        let mut chunk = vec![0u8; size];
        reader.read_exact(&mut chunk).ok()?;
        body.extend_from_slice(&chunk);
        let mut terminator = [0u8; 2];
        reader.read_exact(&mut terminator).ok()?;
    }
}

fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.eq_ignore_ascii_case(name).then(|| value.trim())
    })
}
