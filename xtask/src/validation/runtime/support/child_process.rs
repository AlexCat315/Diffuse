//! A long-running child process spoken to over newline-delimited JSON, used for
//! the stdio MCP server and for the editors the validations launch.

use super::json;
use super::posix::PosixIo;
use crate::support::process_signal::ProcessSignal;
use crate::support::terminal::ToolError;
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

/// How a child's standard stream is connected.
pub enum Stream {
    Inherit,
    Discard,
    Pipe,
    File(std::fs::File),
}

pub struct ChildProcess {
    process: Child,
    stdin: Option<ChildStdin>,
    stdout: Option<std::process::ChildStdout>,
    buffer: Vec<u8>,
}

impl ChildProcess {
    pub fn new(
        executable: &Path,
        arguments: &[String],
        environment: &BTreeMap<String, String>,
        stdin: Stream,
        stdout: Stream,
        stderr: Stream,
    ) -> Result<Self, ToolError> {
        let mut command = Command::new(executable);
        command
            .args(arguments)
            .env_clear()
            .envs(environment.iter());
        command.stdin(match stdin {
            Stream::Pipe => Stdio::piped(),
            Stream::Discard => Stdio::null(),
            Stream::Inherit => Stdio::inherit(),
            Stream::File(file) => Stdio::from(file),
        });
        command.stdout(match stdout {
            Stream::Pipe => Stdio::piped(),
            Stream::Discard => Stdio::null(),
            Stream::Inherit => Stdio::inherit(),
            Stream::File(file) => Stdio::from(file),
        });
        command.stderr(match stderr {
            Stream::Pipe => Stdio::piped(),
            Stream::Discard => Stdio::null(),
            Stream::Inherit => Stdio::inherit(),
            Stream::File(file) => Stdio::from(file),
        });
        let mut process = command.spawn().map_err(|error| {
            ToolError::message(format!("Cannot launch {}: {error}", executable.display()))
        })?;
        let input = process.stdin.take();
        let output = process.stdout.take();
        Ok(Self {
            process,
            stdin: input,
            stdout: output,
            buffer: Vec::new(),
        })
    }

    pub fn is_running(&mut self) -> bool {
        matches!(self.process.try_wait(), Ok(None))
    }

    pub fn process_identifier(&self) -> i32 {
        self.process.id() as i32
    }

    pub fn send_line(&mut self, object: &Value) -> Result<(), ToolError> {
        let mut bytes = json::data(object, false);
        bytes.push(b'\n');
        self.send(&bytes)
    }

    pub fn send(&mut self, data: &[u8]) -> Result<(), ToolError> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| ToolError::message("Child process standard input is not piped"))?;
        stdin.write_all(data).map_err(|error| {
            ToolError::message(format!("Cannot write to child process: {error}"))
        })
    }

    pub fn close_input(&mut self) {
        // Dropping the handle closes the pipe, as `fileHandleForWriting.close()`
        // does; a second call is a no-op.
        self.stdin.take();
    }

    /// Next JSON line, or `None` when nothing arrived within `timeout`.
    pub fn read_line(&mut self, timeout: f64) -> Result<Option<Value>, ToolError> {
        if let Some(line) = self.take_line()? {
            return Ok(Some(line));
        }
        let stdout = self
            .stdout
            .as_mut()
            .ok_or_else(|| ToolError::message("Child process standard output is not piped"))?;
        let descriptor = std::os::fd::AsRawFd::as_raw_fd(stdout);
        let deadline = Instant::now() + Duration::from_secs_f64(timeout.max(0.0));
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Ok(None);
            }
            if PosixIo::readable(&[descriptor], remaining.as_secs_f64())?.is_empty() {
                continue;
            }
            match PosixIo::read(descriptor, 65536) {
                Some(chunk) => {
                    self.buffer.extend_from_slice(&chunk);
                    if let Some(line) = self.take_line()? {
                        return Ok(Some(line));
                    }
                }
                None => {
                    return Err(ToolError::message(
                        "Child process exited before responding",
                    ));
                }
            }
        }
    }

    /// Blocks until exit, returning the status or `None` on timeout.
    pub fn wait(&mut self, timeout: f64) -> Option<i32> {
        let deadline = Instant::now() + Duration::from_secs_f64(timeout.max(0.0));
        loop {
            match self.process.try_wait() {
                Ok(Some(status)) => return Some(status.code().unwrap_or(0)),
                Ok(None) => {}
                Err(_) => return None,
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    pub fn terminate(&mut self) {
        if matches!(self.process.try_wait(), Ok(None)) {
            let _ = self.process.kill();
        }
    }

    pub fn kill(&mut self) {
        ProcessSignal::kill(&mut self.process);
    }

    /// Terminate with a grace period, escalating to a hard kill, then reap.
    pub fn stop(&mut self) {
        if !matches!(self.process.try_wait(), Ok(None)) {
            return;
        }
        if self.wait(0.0).is_some() {
            return;
        }
        // Std's `kill` sends SIGKILL on Unix and TerminateProcess on Windows;
        // the Swift original's softer `terminate()` is the grace step here.
        if self.wait(5.0).is_none() {
            self.kill();
            let _ = self.wait(5.0);
        }
    }

    fn take_line(&mut self) -> Result<Option<Value>, ToolError> {
        let Some(index) = self.buffer.iter().position(|byte| *byte == b'\n') else {
            return Ok(None);
        };
        let line: Vec<u8> = self.buffer.drain(..=index).collect();
        Ok(Some(json::parse(&line[..line.len() - 1])?))
    }
}

impl Drop for ChildProcess {
    fn drop(&mut self) {
        // Leaving a child running would outlive the validation that spawned it.
        if matches!(self.process.try_wait(), Ok(None)) {
            let _ = self.process.kill();
            let _ = self.process.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment() -> BTreeMap<String, String> {
        std::env::vars().collect()
    }

    #[test]
    fn lines_round_trip_as_json_objects() {
        let sh = crate::support::shell::require("sh", &environment()).unwrap();
        let mut child = ChildProcess::new(
            &sh,
            &["-c".to_string(), "read line; echo \"$line\"".to_string()],
            &environment(),
            Stream::Pipe,
            Stream::Pipe,
            Stream::Discard,
        )
        .unwrap();
        child
            .send_line(&serde_json::json!({"jsonrpc": "2.0", "id": 1}))
            .unwrap();
        let line = child.read_line(5.0).unwrap().expect("a reply");
        assert_eq!(line["id"], serde_json::json!(1));
        child.stop();
    }

    #[test]
    fn a_closed_child_reports_exit_rather_than_hanging() {
        let sh = crate::support::shell::require("sh", &environment()).unwrap();
        let mut child = ChildProcess::new(
            &sh,
            &["-c".to_string(), "exit 0".to_string()],
            &environment(),
            Stream::Pipe,
            Stream::Pipe,
            Stream::Discard,
        )
        .unwrap();
        assert_eq!(child.wait(5.0), Some(0));
        assert!(!child.is_running());
    }
}
