//! One error type for every repository tool, so the CLI can print a single
//! actionable line and return a non-zero status without leaking internals.

use std::io::{self, Write};

/// Failure shared by every Cove command line tool.
#[derive(Debug, thiserror::Error)]
pub enum ToolError {
    #[error("{0}")]
    Message(String),
    #[error("{command} exited with status {status}")]
    Command { command: String, status: i32 },
}

impl ToolError {
    /// Matches Swift's `.message(String)` case.
    pub fn message(text: impl Into<String>) -> Self {
        Self::Message(text.into())
    }

    /// Matches Swift's `.command(String, Int32)` case.
    pub fn command(command: impl Into<String>, status: i32) -> Self {
        Self::Command {
            command: command.into(),
            status,
        }
    }
}

/// Human-facing terminal output. Warnings and errors never interleave with
/// machine-readable stdout.
pub struct Terminal;

impl Terminal {
    pub fn info(text: &str) {
        println!("{text}");
    }

    pub fn warning(text: &str) {
        let mut stderr = io::stderr().lock();
        let _ = writeln!(stderr, "warning: {text}");
    }

    pub fn error(text: &str) {
        let mut stderr = io::stderr().lock();
        let _ = writeln!(stderr, "error: {text}");
    }

    /// Prints the error and terminates with status 1.
    pub fn fail(text: &str) -> ! {
        Self::error(text);
        std::process::exit(1);
    }

    /// Flattens any error into the one actionable line and terminates with
    /// status 1, matching `Terminal.fail(_ error: any Error)`.
    pub fn fail_error(error: &dyn std::error::Error) -> ! {
        Self::fail(&error.to_string())
    }
}
