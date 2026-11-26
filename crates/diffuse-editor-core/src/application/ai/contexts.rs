//! `Editor/Sources/EditorCore/Application/AI/Contexts.swift`.
//!
//! The package context the active agent lists, read just before a request.

use std::collections::BTreeMap;

use diffuse_ai::session::session_workflow_scope::SessionContextSection;
use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::ai::context::AIContextContributionPoint;

use crate::application::editor_application::EditorApplication;
use crate::application::plugins::commands::PluginEntryPointError;
use crate::ai::chat::editor_agent_task_service::EditorAgentTaskTarget;
use crate::contributions::host::{StepError, StepPlugin, StepPlugins, StepProvider};
use crate::contributions::steps::StepOutcome;
use crate::state::editor_state::EditorConsoleSeverity;

impl EditorApplication {
    /// The package context the active agent lists, read just before a request.
    /// A source that fails is left out and reported; the request still goes on.
    pub fn agent_context_sections(
        &self,
        target: &EditorAgentTaskTarget,
    ) -> Vec<SessionContextSection> {
        let Some(agent) = self
            .agent_catalog()
            .agent(&self.store.ai_settings().agent_id)
            .cloned()
        else {
            return Vec::new();
        };
        let contexts = agent.package_contexts();
        if contexts.is_empty() {
            return Vec::new();
        }
        let selection = serde_json::to_vec(
            &target
                .selected_entity_ids
                .iter()
                .map(|id| format!("scene:{id}"))
                .collect::<Vec<_>>(),
        )
        .unwrap_or_else(|_| b"[]".to_vec());
        let selection = String::from_utf8_lossy(&selection).into_owned();
        let mut sections: Vec<SessionContextSection> = Vec::new();
        let packages: Vec<ValidatedPluginPackage> = self
            .plugin_session
            .contributions
            .contexts
            .snapshot()
            .values
            .into_iter()
            .map(|value| value.value)
            .collect();
        for package in packages {
            for context in package
                .manifest
                .contributes
                .decode_lossy::<AIContextContributionPoint>()
            {
                if !contexts.contains(&context.id) {
                    continue;
                }
                match self.context_text(&context, &package, target.content.raw_value(), &selection)
                {
                    Ok(text) if !text.is_empty() => sections.push(SessionContextSection::new(
                        &context.title,
                        Self::prefix(&text, context.byte_limit() as usize),
                    )),
                    Ok(_) => {}
                    // Without the tool installed the source has nothing to say.
                    Err(ContextFailure::Step(StepError::ToolMissing(_))) => {}
                    Err(error) => self.log_console(
                        &format!("{} context was left out", context.title),
                        EditorConsoleSeverity::Warning,
                        Some(error.to_string()),
                        None,
                        None,
                    ),
                }
            }
        }
        sections
    }

    /// A plain entry point is called once; one with a process permission is
    /// driven through the step protocol, so the editor runs its commands.
    fn context_text(
        &self,
        context: &diffuse_plugin::contribution::ai::context::AIContextContribution,
        package: &ValidatedPluginPackage,
        content: &str,
        selection: &str,
    ) -> Result<String, ContextFailure> {
        if package.manifest.host.processes.is_empty() {
            let mut input = BTreeMap::new();
            input.insert("content".to_string(), content.to_string());
            input.insert("selection".to_string(), selection.to_string());
            let payload = self
                .read_entry_point(
                    &package.manifest.id,
                    &context.entry_point,
                    "onAIChat",
                    &input,
                )
                .map_err(ContextFailure::EntryPoint)?;
            // The entry point returns its text as a JSON string.
            return serde_json::from_slice::<String>(&payload)
                .map_err(|error| ContextFailure::Decode(error.to_string()));
        }
        let Some(process) = package
            .manifest
            .host
            .processes
            .iter()
            .find(|process| process.entry_points.contains(&context.entry_point))
            .cloned()
        else {
            let mut input = BTreeMap::new();
            input.insert("content".to_string(), content.to_string());
            input.insert("selection".to_string(), selection.to_string());
            let payload = self
                .read_entry_point(
                    &package.manifest.id,
                    &context.entry_point,
                    "onAIChat",
                    &input,
                )
                .map_err(ContextFailure::EntryPoint)?;
            return serde_json::from_slice::<String>(&payload)
                .map_err(|error| ContextFailure::Decode(error.to_string()));
        };
        let provider = StepProvider {
            plugin_id: package.manifest.id.clone(),
            title: context.title.clone(),
            package: package.root_url.clone(),
            entry_point: context.entry_point.clone(),
            activation_event: "onAIChat".to_string(),
            process,
        };
        let plugin: StepPlugin =
            StepPlugins::new(self.plugin_session.runtime.clone())
                .plugin(&provider, std::path::Path::new(&self.project_directory))
                .map_err(ContextFailure::Step)?;
        let operation = serde_json::json!({
            "op": "context",
            "content": content,
            "selection": selection,
        });
        match plugin
            .perform(&operation, None, StepPlugin::WINDOW, None, None)
            .map_err(ContextFailure::Step)?
        {
            StepOutcome::Result(data) => serde_json::from_slice::<String>(&data)
                .map_err(|error| ContextFailure::Decode(error.to_string())),
            StepOutcome::Output(text) => Ok(text),
        }
    }

}

/// Everything that can stop one context source.
#[derive(Debug, thiserror::Error)]
pub enum ContextFailure {
    #[error("{0}")]
    Step(#[from] StepError),
    #[error("{0}")]
    EntryPoint(PluginEntryPointError),
    #[error("{0}")]
    Decode(String),
}
