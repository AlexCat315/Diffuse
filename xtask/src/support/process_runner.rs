//! Tool boundary: resolves PATH and chooses capture or live output; process IO
//! is shared with applications. No argument string is ever interpreted by a
//! shell.

use super::shell;
use super::terminal::ToolError;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Output budget shared with `ProcessRunner`.
pub const OUTPUT_BYTES: usize = 33_554_432;
pub const PENDING_INPUT_BYTES: usize = 33_554_432;

#[derive(Debug, thiserror::Error)]
pub enum ProcessError {
    #[error("invalid process budget")]
    InvalidBudget,
    #[error("process output exceeded its budget")]
    OutputLimit,
    #[error("{0}")]
    Io(#[from] io::Error),
}

impl From<ProcessError> for ToolError {
    fn from(error: ProcessError) -> Self {
        ToolError::message(error.to_string())
    }
}

#[derive(Debug, Default, Clone)]
pub struct ProcessOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// 0 when the process did not report a status.
    pub status: i32,
}

impl ProcessOutput {
    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr).into_owned()
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ProcessOptions<'a> {
    pub directory: Option<&'a Path>,
    pub input: Option<&'a [u8]>,
    pub timeout: Option<Duration>,
    pub merge_error: bool,
    pub stream: bool,
}

struct Sink {
    collected: Arc<Mutex<Vec<u8>>>,
    limit: usize,
    overflowed: Arc<AtomicBool>,
}

impl Sink {
    fn append(&self, data: &[u8]) {
        let mut buffer = self
            .collected
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if buffer.len() + data.len() > self.limit {
            let remaining = self.limit.saturating_sub(buffer.len());
            buffer.extend_from_slice(&data[..remaining.min(data.len())]);
            self.overflowed.store(true, Ordering::Relaxed);
        } else {
            buffer.extend_from_slice(data);
        }
    }
}

/// Runs a child process with a byte budget, optional stdin, timeout and
/// streaming. `stderr` folds into `stdout` when `merge_error` is set.
pub fn run(
    arguments: &[String],
    environment: &BTreeMap<String, String>,
    options: ProcessOptions<'_>,
) -> Result<ProcessOutput, ProcessError> {
    let executable = arguments.first().ok_or_else(|| {
        ProcessError::Io(io::Error::new(io::ErrorKind::InvalidInput, "Empty command"))
    })?;
    if let Some(timeout) = options.timeout
        && !timeout.is_zero()
        && timeout > Duration::from_secs(86_400)
    {
        return Err(ProcessError::InvalidBudget);
    }
    let resolved = shell::require(executable, environment).map_err(|error| {
        ProcessError::Io(io::Error::new(io::ErrorKind::NotFound, error.to_string()))
    })?;
    let directory = options
        .directory
        .map(Path::to_path_buf)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| ".".into()));
    let mut command = Command::new(&resolved);
    command
        .args(&arguments[1..])
        .current_dir(&directory)
        .envs(environment.iter())
        .stdin(if options.input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;

    if let Some(input) = options.input {
        if input.len() > PENDING_INPUT_BYTES {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ProcessError::InvalidBudget);
        }
        if let Some(mut stdin) = child.stdin.take() {
            let data = input.to_vec();
            // A child that exits before reading must not abort the run.
            let _ = stdin.write_all(&data);
        }
    }
    let stdout_pipe = child.stdout.take();
    let stderr_pipe = child.stderr.take();

    let stdout = Arc::new(Mutex::new(Vec::new()));
    let stderr = Arc::new(Mutex::new(Vec::new()));
    let overflowed = Arc::new(AtomicBool::new(false));
    let mut readers: Vec<JoinHandle<()>> = Vec::new();

    readers.push(spawn_reader(
        stdout_pipe,
        Sink {
            collected: Arc::clone(&stdout),
            limit: OUTPUT_BYTES,
            overflowed: Arc::clone(&overflowed),
        },
        options.stream.then_some(StreamTarget::Stdout),
    ));
    readers.push(spawn_reader(
        stderr_pipe,
        Sink {
            collected: Arc::clone(&stderr),
            limit: OUTPUT_BYTES,
            overflowed: Arc::clone(&overflowed),
        },
        if !options.stream {
            None
        } else if options.merge_error {
            Some(StreamTarget::Stdout)
        } else {
            Some(StreamTarget::Stderr)
        },
    ));

    let deadline = options.timeout.map(|timeout| Instant::now() + timeout);
    let mut status: Option<i32> = None;
    loop {
        if let Some(exit) = child.try_wait()? {
            status = exit.code();
            break;
        }
        if overflowed.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            for reader in readers {
                let _ = reader.join();
            }
            return Err(ProcessError::OutputLimit);
        }
        if let Some(deadline) = deadline
            && Instant::now() >= deadline
        {
            let _ = child.kill();
            let _ = child.wait();
            let _ = status;
            for reader in readers {
                let _ = reader.join();
            }
            return Err(ProcessError::InvalidBudget);
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    for reader in readers {
        let _ = reader.join();
    }

    let stdout = std::mem::take(&mut *stdout.lock().unwrap_or_else(|error| error.into_inner()));
    let stderr = std::mem::take(&mut *stderr.lock().unwrap_or_else(|error| error.into_inner()));
    if overflowed.load(Ordering::Relaxed) {
        return Err(ProcessError::OutputLimit);
    }
    let mut result = ProcessOutput {
        stdout,
        stderr,
        status: status.unwrap_or(0),
    };
    if options.merge_error {
        result.stdout.extend_from_slice(&result.stderr);
        result.stderr.clear();
    }
    Ok(result)
}

#[derive(Clone, Copy)]
enum StreamTarget {
    Stdout,
    Stderr,
}

fn spawn_reader(
    pipe: Option<impl Read + Send + 'static>,
    sink: Sink,
    stream: Option<StreamTarget>,
) -> JoinHandle<()> {
    std::thread::spawn(move || {
        let Some(mut pipe) = pipe else { return };
        let mut chunk = [0u8; 16 * 1024];
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) => break,
                Ok(read) => {
                    sink.append(&chunk[..read]);
                    match stream {
                        Some(StreamTarget::Stdout) => {
                            let mut out = io::stdout().lock();
                            let _ = out.write_all(&chunk[..read]);
                            let _ = out.flush();
                        }
                        Some(StreamTarget::Stderr) => {
                            let mut err = io::stderr().lock();
                            let _ = err.write_all(&chunk[..read]);
                            let _ = err.flush();
                        }
                        None => {}
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    })
}

/// Convenience wrapper mirroring Swift's `ProcessRunner` namespace.
pub struct ProcessRunner;

impl ProcessRunner {
    pub fn run(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
        options: ProcessOptions<'_>,
    ) -> Result<ProcessOutput, ProcessError> {
        run(arguments, environment, options)
    }
}
