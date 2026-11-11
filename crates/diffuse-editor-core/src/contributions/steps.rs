//! `Editor/Sources/EditorCore/Contributions/Steps.swift`.
//!
//! The editor half of the step protocol: the plugin decides each command, the
//! editor runs it through the plugin's process permission and calls back with
//! its output until the plugin returns a result.
//!
//! Output goes to the plugin a window at a time. The plugin answers each window
//! with a fragment of the result and how much it read, so each call stays short
//! however much a command prints; one that reads nothing gets a wider window.
//! Swift awaited the plugin; the port is blocking, so waits sleep and a caller's
//! cancellation token is checked between steps.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use diffuse_plugin::base64_data::Data;
use diffuse_plugin::processes::contract::{Operation, PluginProcessRequest, PluginProcessUpdate};
use serde_json::{Map, Value};

use crate::contributions::host::{StepError, StepPlugin};

/// What an operation produced: the plugin's JSON result, or the standard
/// output of a command whose output is the result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StepOutcome {
    Result(Vec<u8>),
    Output(String),
}

/// Swift's nested `StepPlugin.Output`; Rust carries it at module scope.
#[derive(Clone, Debug, Default)]
pub struct StepOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Both streams in the order they were read.
    pub combined: Vec<u8>,
    pub status: i32,
}

impl StepPlugin {
    pub const WINDOW: usize = 1 << 20;

    /// Runs `operation` to its result. `resuming` continues as if a command had
    /// just printed `stdout`, for recorded output; `base_window` sizes windows.
    pub fn perform(
        &self,
        operation: &Value,
        resuming: Option<(&str, &[u8])>,
        base_window: usize,
        on_output: Option<&dyn Fn(&[u8])>,
        cancel: Option<&AtomicBool>,
    ) -> Result<StepOutcome, StepError> {
        let request_map = operation.as_object().cloned().unwrap_or_default();
        let name = request_map
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or("operation")
            .to_string();
        let failed = |message: String| StepError::CommandFailed {
            command: format!("{} {name}", self.provider.title),
            message,
        };
        let mut request = request_map.clone();
        // The last command's output, made valid UTF-8 once so window offsets
        // mean the same bytes on both sides.
        let mut pending: Vec<u8> = Vec::new();
        let mut offset: usize = 0;
        let mut window = base_window;
        if let Some((next, stdout)) = resuming {
            request.insert("next".to_string(), Value::String(next.to_string()));
            request.insert(
                "output".to_string(),
                serde_json::json!({ "exit": 0, "stderr": "" }),
            );
            pending = String::from_utf8_lossy(stdout).into_owned().into_bytes();
        }
        let mut fragments: Vec<u8> = Vec::new();
        for _ in 0..100_000 {
            let mut stdout = String::new();
            if let Some(output) = request.get_mut("output").and_then(Value::as_object_mut) {
                let end = Self::window_end(&pending, offset, window);
                stdout = String::from_utf8_lossy(&pending[offset..end]).into_owned();
                output.insert("offset".to_string(), serde_json::json!(offset));
                output.insert(
                    "complete".to_string(),
                    serde_json::json!(end == pending.len()),
                );
            }
            let step = self.call(&Value::Object(request.clone()), &stdout)?;
            if let Some(message) = step.get("error").and_then(Value::as_str) {
                return Err(failed(message.to_string()));
            }
            if let Some(result) = step.get("result") {
                let bytes = serde_json::to_vec(result)
                    .map_err(|error| StepError::ProtocolViolation(error.to_string()))?;
                return Ok(StepOutcome::Result(bytes));
            }
            if let Some(fragment) = step.get("emit").and_then(Value::as_str) {
                fragments.extend_from_slice(fragment.as_bytes());
                if step.get("done").and_then(Value::as_bool) == Some(true) {
                    return Ok(StepOutcome::Result(fragments));
                }
                let consumed = step.get("consumed").and_then(Value::as_i64).unwrap_or(0);
                let end = Self::window_end(&pending, offset, window);
                let next = step.get("next").and_then(Value::as_str);
                let beyond_window = consumed < 0 || (offset as i64 + consumed) > end as i64;
                let Some(next) = next else {
                    return Err(StepError::ProtocolViolation(format!(
                        "The {} plugin sent an unknown step.",
                        self.provider.title
                    )));
                };
                if beyond_window {
                    return Err(StepError::ProtocolViolation(format!(
                        "The {} plugin read past its window.",
                        self.provider.title
                    )));
                }
                if consumed > 0 {
                    offset += consumed as usize;
                    window = base_window;
                } else if end < pending.len() {
                    window *= 2;
                } else {
                    return Err(StepError::ProtocolViolation(format!(
                        "The {} plugin stopped reading {name}'s output.",
                        self.provider.title
                    )));
                }
                request.insert("next".to_string(), Value::String(next.to_string()));
                continue;
            }
            request = request_map.clone();
            if let (Some(paths), Some(next)) = (
                step.get("trash").and_then(Value::as_array),
                step.get("next").and_then(Value::as_str),
            ) {
                let paths: Vec<String> = paths
                    .iter()
                    .filter_map(|path| path.as_str().map(str::to_string))
                    .collect();
                Self::trash(&paths, &self.workspace)?;
                request.insert("next".to_string(), Value::String(next.to_string()));
                continue;
            }
            let Some(arguments) = step.get("run").and_then(Value::as_array) else {
                return Err(StepError::ProtocolViolation(format!(
                    "The {} plugin sent an unknown step.",
                    self.provider.title
                )));
            };
            let arguments: Vec<String> = arguments
                .iter()
                .filter_map(|argument| argument.as_str().map(str::to_string))
                .collect();
            let next = step.get("next").and_then(Value::as_str);
            let streams = step.get("stream").and_then(Value::as_bool) == Some(true);
            let environment: BTreeMap<String, String> = step
                .get("env")
                .and_then(Value::as_object)
                .map(|object| {
                    object
                        .iter()
                        .filter_map(|(key, value)| {
                            value.as_str().map(|value| (key.clone(), value.to_string()))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let timeout = if streams {
                None
            } else {
                Some(Duration::from_secs(
                    step.get("timeout").and_then(Value::as_i64).unwrap_or(60) as u64,
                ))
            };
            let output = self.run(
                &arguments,
                step.get("input").and_then(Value::as_str),
                &environment,
                timeout,
                if streams { on_output } else { None },
                cancel,
            )?;
            let Some(next) = next else {
                if output.status != 0 && output.stdout.is_empty() {
                    return Err(failed(String::from_utf8_lossy(&output.stderr).into_owned()));
                }
                return Ok(StepOutcome::Output(
                    String::from_utf8_lossy(&output.stdout).into_owned(),
                ));
            };
            request.insert("next".to_string(), Value::String(next.to_string()));
            let stderr_tail = &output.stderr[output.stderr.len().saturating_sub(16_384)..];
            request.insert(
                "output".to_string(),
                serde_json::json!({
                    "exit": output.status,
                    "stderr": String::from_utf8_lossy(stderr_tail),
                }),
            );
            // A streamed command's output is read as the user saw it, both streams in order.
            let source = if streams {
                &output.combined
            } else {
                &output.stdout
            };
            pending = String::from_utf8_lossy(source).into_owned().into_bytes();
            offset = 0;
            window = base_window;
            fragments.clear();
        }
        Err(StepError::ProtocolViolation(format!(
            "The {} plugin did not finish {name}.",
            self.provider.title
        )))
    }

    fn call(&self, request: &Value, stdout: &str) -> Result<Value, StepError> {
        let encoded = serde_json::to_string(request)
            .map_err(|error| StepError::ProtocolViolation(error.to_string()))?;
        let response = self.invoke(&encoded, stdout)?;
        let step: Value = serde_json::from_slice(&response).map_err(|_| {
            StepError::ProtocolViolation(format!(
                "The {} plugin sent a malformed step.",
                self.provider.title
            ))
        })?;
        if step.is_object() {
            Ok(step)
        } else {
            Err(StepError::ProtocolViolation(format!(
                "The {} plugin sent a malformed step.",
                self.provider.title
            )))
        }
    }

    /// Where a window of at most `length` bytes ends: before a UTF-8
    /// continuation byte, so a character is never split.
    pub fn window_end(data: &[u8], start: usize, length: usize) -> usize {
        let limit = (start + length).min(data.len());
        let mut end = limit;
        while end < data.len() && end > start && data[end] & 0xC0 == 0x80 {
            end -= 1;
        }
        if end == start { limit } else { end }
    }

    /// Workspace-relative paths go to the Trash, so removing them can be undone.
    fn trash(paths: &[String], root: &Path) -> Result<(), StepError> {
        for path in paths {
            diffuse_documents::trash::WorkspaceTrash::remove(path, root).map_err(|error| {
                StepError::ProtocolViolation(format!("Could not move {path} to the Trash: {error}"))
            })?;
        }
        Ok(())
    }

    // MARK: Processes

    /// Runs one command under the manifest's process permission, through the
    /// plugin host that enforces it. Without a timeout it runs until it exits
    /// or the caller cancels.
    fn run(
        &self,
        arguments: &[String],
        input: Option<&str>,
        environment: &BTreeMap<String, String>,
        timeout: Option<Duration>,
        on_output: Option<&dyn Fn(&[u8])>,
        cancel: Option<&AtomicBool>,
    ) -> Result<StepOutput, StepError> {
        let rule = &self.provider.process;
        let mut start = PluginProcessRequest::new(Operation::Start);
        start.permission = Some(rule.id.clone());
        start.arguments = rule.argument_prefix.clone();
        start.arguments.extend_from_slice(arguments);
        start.environment = self.tool.environment_for_keys(&rule.environment_keys);
        for (key, value) in environment {
            if rule.environment_keys.contains(key) {
                start.environment.insert(key.clone(), value.clone());
            }
        }
        let update = self.process(&start)?;
        let handle = update.handle;
        let failure = (|| -> Result<StepOutput, StepError> {
            let bytes = input.unwrap_or("").as_bytes();
            let mut offset = 0;
            while offset < bytes.len() {
                let end = (offset + 8_192).min(bytes.len());
                let mut write = PluginProcessRequest::new(Operation::Write);
                write.handle = Some(handle.clone());
                write.input = Some(Data::from_bytes(bytes[offset..end].to_vec()));
                let _ = self.process(&write)?;
                offset = end;
            }
            let mut close = PluginProcessRequest::new(Operation::CloseInput);
            close.handle = Some(handle.clone());
            let _ = self.process(&close)?;

            let mut output = StepOutput::default();
            let mut delay_ms: u64 = 2;
            let deadline = timeout.map(|timeout| Instant::now() + timeout);
            let mut poll = PluginProcessRequest::new(Operation::Poll);
            poll.handle = Some(handle.clone());
            loop {
                if cancel.is_some_and(|token| token.load(Ordering::SeqCst)) {
                    return Err(StepError::Cancelled);
                }
                let update = self.process(&poll)?;
                output.stdout.extend_from_slice(update.stdout.as_slice());
                output.stderr.extend_from_slice(update.stderr.as_slice());
                output.combined.extend_from_slice(update.stdout.as_slice());
                output.combined.extend_from_slice(update.stderr.as_slice());
                if let Some(on_output) = on_output {
                    if !update.stdout.is_empty() {
                        on_output(update.stdout.as_slice());
                    }
                    if !update.stderr.is_empty() {
                        on_output(update.stderr.as_slice());
                    }
                }
                if let Some(failure) = update.failure {
                    return Err(StepError::ProtocolViolation(failure));
                }
                if let Some(status) = update.exit_status {
                    output.status = status;
                    return Ok(output);
                }
                if !update.stdout.is_empty() || !update.stderr.is_empty() {
                    delay_ms = 2;
                    continue;
                }
                if let Some(deadline) = deadline
                    && Instant::now() >= deadline
                {
                    return Err(StepError::CommandFailed {
                        command: format!(
                            "{} {}",
                            self.provider.title,
                            arguments.first().cloned().unwrap_or_default()
                        ),
                        message: "The command did not finish in time.".to_string(),
                    });
                }
                std::thread::sleep(Duration::from_millis(delay_ms));
                delay_ms = (delay_ms * 2).min(if on_output.is_none() { 50 } else { 100 });
            }
        })();
        if failure.is_err() {
            let mut stop = PluginProcessRequest::new(Operation::Stop);
            stop.handle = Some(handle.clone());
            let _ = self.process(&stop);
        }
        failure
    }

    /// Process requests reach `cove:process/host` through the plugin, which
    /// forwards the text after `{"process":` unparsed; the host checks it
    /// against the manifest.
    fn process(&self, request: &PluginProcessRequest) -> Result<PluginProcessUpdate, StepError> {
        let request_value = serde_json::to_value(request)
            .map_err(|error| StepError::ProtocolViolation(error.to_string()))?;
        let forwarded = format!(
            "{{\"process\":{}}}",
            serde_json::to_string(&request_value)
                .map_err(|error| StepError::ProtocolViolation(error.to_string()))?
        );
        let response = self.invoke(&forwarded, "")?;
        serde_json::from_slice(&response)
            .map_err(|error| StepError::ProtocolViolation(error.to_string()))
    }
}

impl std::fmt::Debug for StepPlugin {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("StepPlugin")
            .field("provider", &self.provider)
            .field("workspace", &self.workspace)
            .finish()
    }
}
