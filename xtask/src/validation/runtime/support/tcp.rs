//! Line-oriented loopback TCP client used for the editor's JSON bridge and for
//! waiting until that bridge accepts connections.

use super::posix::PosixIo;
use crate::support::terminal::ToolError;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

pub struct TcpClient {
    stream: TcpStream,
    buffer: Vec<u8>,
}

impl TcpClient {
    pub fn new(host: &str, port: u16, timeout: f64) -> Result<Self, ToolError> {
        let timeout = Duration::from_secs_f64(timeout.max(0.0));
        let address = (host, port)
            .to_socket_addrs()
            .map_err(|error| {
                ToolError::message(format!("connect to {host}:{port} failed: {error}"))
            })?
            .next()
            .ok_or_else(|| {
                ToolError::message(format!("connect to {host}:{port} failed: no address"))
            })?;
        let stream = TcpStream::connect_timeout(&address, timeout).map_err(|error| {
            ToolError::message(format!("connect to {host}:{port} failed: {error}"))
        })?;
        stream.set_nodelay(true).ok();
        Ok(Self {
            stream,
            buffer: Vec::new(),
        })
    }

    pub fn send(&mut self, data: &[u8]) -> Result<(), ToolError> {
        use std::io::Write;
        self.stream
            .write_all(data)
            .map_err(|error| ToolError::message(format!("write failed: {error}")))
    }

    pub fn read_line(&mut self, timeout: f64) -> Result<Vec<u8>, ToolError> {
        use std::io::Read;
        let deadline = Instant::now() + Duration::from_secs_f64(timeout.max(0.0));
        loop {
            if let Some(index) = self.buffer.iter().position(|byte| *byte == b'\n') {
                return Ok(self.buffer.drain(..=index).take(index).collect());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                if self.buffer.is_empty() {
                    return Err(ToolError::message("Timed out waiting for a bridge reply"));
                }
                return Ok(std::mem::take(&mut self.buffer));
            }
            self.stream.set_read_timeout(Some(remaining)).ok();
            let mut chunk = vec![0u8; 65536];
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    if self.buffer.is_empty() {
                        return Err(ToolError::message("Timed out waiting for a bridge reply"));
                    }
                    return Ok(std::mem::take(&mut self.buffer));
                }
                Ok(read) => self.buffer.extend_from_slice(&chunk[..read]),
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        || error.kind() == std::io::ErrorKind::TimedOut =>
                {
                    if self.buffer.is_empty() {
                        return Err(ToolError::message("Timed out waiting for a bridge reply"));
                    }
                    return Ok(std::mem::take(&mut self.buffer));
                }
                Err(error) => {
                    return Err(ToolError::message(format!("read failed: {error}")));
                }
            }
        }
    }

    pub fn close(self) {
        drop(self.stream);
    }
}

/// Asks the kernel for an unused loopback port, the way the Python originals
/// bound a probe socket to port 0.
pub struct FreePort;

impl FreePort {
    pub fn reserve() -> Result<u16, ToolError> {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0))
            .map_err(|error| ToolError::message(format!("socket failed: {error}")))?;
        let port = listener
            .local_addr()
            .map_err(|error| ToolError::message(format!("getsockname failed: {error}")))?
            .port();
        drop(listener);
        Ok(port)
    }
}

/// One descriptor's readiness, exposed for the Windows-less hosts that need it.
pub fn readable(descriptor: i32, timeout: f64) -> Result<bool, ToolError> {
    Ok(!PosixIo::readable(&[descriptor], timeout)?.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // The Swift case binds a listening socket, connects, and asserts the
    // connect completes before the server sends anything.
    #[test]
    fn connect_completes_before_the_server_sends_data() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("listen");
        let port = listener.local_addr().unwrap().port();
        let client = TcpClient::new("127.0.0.1", port, 2.0).expect("connect");
        client.close();
        drop(listener);
    }

    #[test]
    fn lines_are_delimited_by_newline() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("listen");
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            stream.write_all(b"first\nsecond\n").expect("write");
        });
        let mut client = TcpClient::new("127.0.0.1", port, 2.0).expect("connect");
        assert_eq!(client.read_line(2.0).expect("line"), b"first");
        assert_eq!(client.read_line(2.0).expect("line"), b"second");
        server.join().expect("server");
    }

    #[test]
    fn free_ports_are_usable() {
        let port = FreePort::reserve().expect("port");
        assert_ne!(port, 0);
    }

    #[test]
    fn an_unreachable_port_reports_the_endpoint() {
        let port = FreePort::reserve().expect("port");
        let error = match TcpClient::new("127.0.0.1", port, 0.2) {
            Ok(_) => panic!("a reserved port must not accept connections"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("127.0.0.1"));
    }
}
