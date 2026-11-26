//! One-shot text completions provided by the configured plugin.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use diffuse_plugin::contribution::services::PluginServiceContributionPoint;
use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;
use serde_json::{Value, json};
use unicode_segmentation::UnicodeSegmentation;

use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::EditorApplication;
use crate::contributions::runtime_access::PluginRuntimeAccess;

const SERVICE_ID: &str = "diffuse.ai.completion/v1";

impl EditorApplication {
    /// Drafts a commit message from staged changes or, when none are staged, all changes.
    pub fn draft_commit_message(
        &self,
        cancelled: Arc<AtomicBool>,
    ) -> Result<JoinHandle<Result<String, EditorProjectToolError>>, EditorProjectToolError> {
        let workstation = self.workstation.clone();
        let snapshot = workstation.version_control.snapshot();
        if snapshot.staged().is_empty() && snapshot.unstaged().is_empty() {
            return Err(EditorProjectToolError::new(
                "There are no changes to describe.",
            ));
        }
        let service = self.completion_service()?;
        thread::Builder::new()
            .name("diffuse.commit-message".into())
            .spawn(move || {
                let mut changes = snapshot.staged();
                if changes.is_empty() {
                    changes = snapshot.unstaged();
                }
                let mut budget = 40_000;
                let mut sections = Vec::new();
                for change in changes.into_iter().take(40) {
                    check_cancellation(&cancelled)?;
                    let mut section = format!("{}: {}", change.state.raw_value(), change.path);
                    if budget > 0 {
                        let diff = workstation.version_control.diff(change);
                        let mut end = 0;
                        for (offset, grapheme) in diff.grapheme_indices(true).take(budget.min(8_000)) {
                            end = offset + grapheme.len();
                            budget -= 1;
                        }
                        if end > 0 {
                            section.push('\n');
                            section.push_str(&diff[..end]);
                        }
                    }
                    sections.push(section);
                }
                let recent = snapshot.history.iter().take(8).map(|revision| revision.summary.as_str()).collect::<Vec<_>>();
                let recent = if recent.is_empty() { "(none)".into() } else { recent.join("\n") };
                let instructions = "Write a commit message for the changes below. Use a concise imperative subject line of at most 72 characters, then a blank line and a short body only when the change needs explanation. Follow the style of the recent messages when they share a convention. Reply with the commit message only.";
                let prompt = format!("Recent commit messages:\n{recent}\n\nChanges:\n{}", sections.join("\n\n"));
                let message = service.complete_text(instructions, &prompt, Some(400), &cancelled)?;
                Ok(message.trim().trim_matches(['`', '"', '\'']).to_owned())
            })
            .map_err(|error| EditorProjectToolError::new(error.to_string()))
    }

    fn completion_service(&self) -> Result<CompletionService, EditorProjectToolError> {
        for package in self.plugin_session.contributions.services.snapshot().values {
            let manifest = &package.value.manifest;
            let services = manifest
                .contributes
                .decode_lossy::<PluginServiceContributionPoint>();
            if let Some(service) = services
                .into_iter()
                .find(|service| service.id == SERVICE_ID)
            {
                return Ok(CompletionService {
                    plugin_id: manifest.id.clone(),
                    capability: format!("{}.{}", manifest.id, service.entry_point),
                    runtime: self.plugin_session.runtime.clone(),
                });
            }
        }
        Err(EditorProjectToolError::new(
            "Enable a plugin providing text completion, then configure its model.",
        ))
    }
}

struct CompletionService {
    plugin_id: String,
    capability: String,
    runtime: Arc<PluginRuntimeAccess>,
}

impl CompletionService {
    fn complete_text(
        &self,
        instructions: &str,
        prompt: &str,
        max_tokens: Option<usize>,
        cancelled: &AtomicBool,
    ) -> Result<String, EditorProjectToolError> {
        check_cancellation(cancelled)?;
        let started = self.invoke(&json!({
            "operation": "start",
            "instructions": instructions,
            "prompt": prompt,
            "maxTokens": max_tokens.unwrap_or(8192).to_string(),
        }))?;
        let handle = started
            .get("handle")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                EditorProjectToolError::new(
                    "The completion service did not return a request handle.",
                )
            })?;
        let result = (|| {
            loop {
                check_cancellation(cancelled)?;
                let update = self.invoke(&json!({ "operation": "poll", "handle": handle }))?;
                check_cancellation(cancelled)?;
                if let Some(error) = update.get("error").and_then(Value::as_str) {
                    return Err(EditorProjectToolError::new(error));
                }
                if update.get("done").and_then(Value::as_bool) == Some(true) {
                    return Ok(update
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned());
                }
                thread::sleep(Duration::from_millis(100));
            }
        })();
        if result.is_err() {
            let _ = self.invoke(&json!({ "operation": "cancel", "handle": handle }));
        }
        result
    }

    fn invoke(&self, request: &Value) -> Result<Value, EditorProjectToolError> {
        let (binding, client) = self
            .runtime
            .resolve(&self.plugin_id, &format!("onService:{SERVICE_ID}"))
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        let input = serde_json::to_vec(&json!({ "request": request.to_string() }))
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        let prepared = client
            .prepare_capability(&binding, &self.capability, &input, None)
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        let PluginPreparedCapabilityResult::Read(data) = prepared else {
            return Err(EditorProjectToolError::new(
                "The completion service returned an invalid result.",
            ));
        };
        serde_json::from_slice(&data)
            .map_err(|error| EditorProjectToolError::new(error.to_string()))
    }
}

fn check_cancellation(cancelled: &AtomicBool) -> Result<(), EditorProjectToolError> {
    if cancelled.load(Ordering::Acquire) {
        Err(EditorProjectToolError::new("Completion cancelled."))
    } else {
        Ok(())
    }
}
