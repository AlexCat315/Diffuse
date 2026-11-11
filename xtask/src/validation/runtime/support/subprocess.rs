//! The validation boundary supplies a deadline and inspects nonzero statuses.

use crate::support::process_runner::{self, ProcessError, ProcessOptions};
use crate::support::terminal::ToolError;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

/// Captured output of one finished child process.
pub struct ProcessOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
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

pub struct Subprocess;

impl Subprocess {
    pub fn run(
        executable: &Path,
        arguments: &[String],
        environment: &BTreeMap<String, String>,
        input: Option<&[u8]>,
        timeout: f64,
    ) -> Result<ProcessOutput, ToolError> {
        let mut command = vec![executable.display().to_string()];
        command.extend_from_slice(arguments);
        Self::run_command(&command, environment, input, timeout)
    }

    pub fn run_command(
        command: &[String],
        environment: &BTreeMap<String, String>,
        input: Option<&[u8]>,
        timeout: f64,
    ) -> Result<ProcessOutput, ToolError> {
        let options = ProcessOptions {
            directory: None,
            input,
            timeout: Some(Duration::from_secs_f64(timeout.max(0.0))),
            merge_error: false,
            stream: false,
        };
        let result = process_runner::run(command, environment, options)
            .map_err(|error| map_error(error, command.first()))?;
        Ok(ProcessOutput {
            stdout: result.stdout,
            stderr: result.stderr,
            status: result.status,
        })
    }
}

fn map_error(error: ProcessError, command: Option<&String>) -> ToolError {
    match error {
        ProcessError::Io(io) => ToolError::message(match command {
            Some(command) => format!("{command}: {io}"),
            None => io.to_string(),
        }),
        other => ToolError::message(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::Subprocess;
    use std::collections::BTreeMap;

    fn environment() -> BTreeMap<String, String> {
        std::env::vars().collect()
    }

    #[test]
    fn nonzero_status_remains_available_to_the_caller() {
        let output = Subprocess::run_command(
            &["sh".into(), "-c".into(), "exit 7".into()],
            &environment(),
            None,
            5.0,
        )
        .expect("runs");
        assert_eq!(output.status, 7);
    }

    #[test]
    fn standard_input_is_delivered() {
        let output =
            Subprocess::run_command(&["cat".into()], &environment(), Some(b"payload"), 5.0)
                .expect("runs");
        assert_eq!(output.stdout, b"payload");
    }
}
