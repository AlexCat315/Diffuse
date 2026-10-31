//! Thin, explicit process launching. Arguments are always passed as a vector;
//! no tool in this package interprets a shell string.

use super::process_runner::{self, ProcessError, ProcessOptions};
use super::terminal::ToolError;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Looks a bare executable name up on `PATH`, honouring `PATHEXT` on Windows.
pub fn executable(name: &str, environment: &BTreeMap<String, String>) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    let path = Path::new(name);
    if path.is_absolute() || path.components().count() > 1 {
        return is_executable(path).then(|| path.to_path_buf());
    }
    let search = environment
        .get("PATH")
        .or_else(|| environment.get("Path"))
        .map(String::as_str)
        .unwrap_or("");
    let extensions: Vec<String> = if cfg!(windows) {
        environment
            .get("PATHEXT")
            .map(|value| {
                value
                    .split(';')
                    .filter(|part| !part.is_empty())
                    .map(|part| part.trim_start_matches('.').to_ascii_lowercase())
                    .collect()
            })
            .unwrap_or_else(|| {
                ["exe", "com", "bat", "cmd"]
                    .iter()
                    .map(|value| (*value).to_string())
                    .collect()
            })
    } else {
        Vec::new()
    };
    for directory in std::env::split_paths(search) {
        if directory.as_os_str().is_empty() {
            continue;
        }
        let candidate = directory.join(name);
        if extensions.is_empty() {
            if is_executable(&candidate) {
                return Some(candidate);
            }
        } else if candidate.extension().is_none() {
            for extension in &extensions {
                let candidate = candidate.with_extension(extension);
                if is_executable(&candidate) {
                    return Some(candidate);
                }
            }
        } else if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// Resolves an executable or reports the same actionable error as Swift.
pub fn require(name: &str, environment: &BTreeMap<String, String>) -> Result<PathBuf, ToolError> {
    executable(name, environment)
        .ok_or_else(|| ToolError::message(format!("Required tool not found on PATH: {name}")))
}

/// Runs to completion and returns trimmed standard output.
pub fn output(
    arguments: &[String],
    at: Option<&Path>,
    environment: &BTreeMap<String, String>,
    echo: bool,
) -> Result<String, ToolError> {
    run(arguments, at, environment, true, echo, None)
}

/// Runs to completion, forwarding the child's standard streams to this tool.
pub fn inherit(
    arguments: &[String],
    at: Option<&Path>,
    environment: &BTreeMap<String, String>,
    input: Option<&str>,
) -> Result<(), ToolError> {
    run(arguments, at, environment, false, true, input).map(|_| ())
}

/// Shared implementation for capture and inherited launches.
pub fn run(
    arguments: &[String],
    at: Option<&Path>,
    environment: &BTreeMap<String, String>,
    capture: bool,
    echo: bool,
    input: Option<&str>,
) -> Result<String, ToolError> {
    let command = arguments
        .first()
        .filter(|command| !command.is_empty())
        .ok_or_else(|| ToolError::message("Empty command"))?;
    if echo {
        println!("$ {}", arguments.join(" "));
    }
    let options = ProcessOptions {
        directory: at,
        input: input.map(str::as_bytes),
        timeout: None,
        merge_error: capture,
        stream: !capture,
    };
    let result = process_runner::run(arguments, environment, options)
        .map_err(|error| map_process_error(error, command))?;
    if result.status != 0 {
        if capture && !result.stdout.is_empty() {
            super::terminal::Terminal::error(&result.stdout_text());
        }
        return Err(ToolError::command(command.clone(), result.status));
    }
    Ok(result.stdout_text().trim().to_string())
}

fn map_process_error(error: ProcessError, command: &str) -> ToolError {
    match error {
        ProcessError::Io(io) => ToolError::message(format!("{command}: {io}")),
        other => ToolError::message(other.to_string()),
    }
}
