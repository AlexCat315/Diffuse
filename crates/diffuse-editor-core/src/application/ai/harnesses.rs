//! `Editor/Sources/EditorCore/Application/AI/Harnesses.swift`.
//!
//! The harness the active agent names, as a step function for the session.

use std::collections::BTreeMap;
use std::error::Error;
use std::sync::Arc;

use diffuse_ai::session::harness::{SessionHarness, SessionHarnessStep, SessionHarnessTurn};
use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::ai::harness::AIHarnessContributionPoint;
use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;

use crate::application::editor_application::EditorApplication;

/// The agent names a harness that no enabled package contributes.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum AgentHarnessError {
    #[error("The agent runs on the {0} harness, which is not enabled.")]
    Unavailable(String),
}

/// A harness, with the identity that keeps its state between turns.
#[derive(Clone)]
pub struct AgentHarness {
    pub driver: SessionHarness,
    pub id: String,
}

impl EditorApplication {
    /// The harness the active agent names. `None` means the built-in loop; a
    /// named harness that is not enabled is an error rather than a silent
    /// fallback.
    pub fn agent_harness(&self) -> Result<Option<AgentHarness>, AgentHarnessError> {
        let catalog = self.agent_catalog();
        let Some(name) = catalog
            .agent(&self.store.ai_settings().agent_id)
            .and_then(|agent| agent.harness.clone())
        else {
            return Ok(None);
        };
        let packages: Vec<ValidatedPluginPackage> = self
            .plugin_session
            .contributions
            .harnesses
            .snapshot()
            .values
            .into_iter()
            .map(|value| value.value)
            .collect();
        for package in packages {
            let contributions = package
                .manifest
                .contributes
                .decode_lossy::<AIHarnessContributionPoint>();
            let Some(harness) = contributions.into_iter().find(|harness| harness.id == name) else {
                continue;
            };
            let plugin_id = package.manifest.id.clone();
            let entry_point = harness.entry_point.clone();
            // The session may drive this from any thread (§5.5), so the closure
            // carries only the runtime handle, never the editor.
            let runtime = self.plugin_session.runtime.clone();
            let identity = format!("{plugin_id}.{name}");
            let identity_in_closure = identity.clone();
            let driver: SessionHarness = Arc::new(move |turn: SessionHarnessTurn| {
                let text = serde_json::to_vec(&turn)
                    .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })?;
                let text = String::from_utf8_lossy(&text).into_owned();
                let mut input = BTreeMap::new();
                input.insert("turn".to_string(), text);
                let data = serde_json::to_vec(&input)
                    .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })?;
                let (binding, client) = runtime
                    .resolve(&plugin_id, "onAIChat")
                    .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })?;
                let capability_id = format!("{plugin_id}.{entry_point}");
                let result = client
                    .prepare_capability(&binding, &capability_id, &data, None)
                    .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })?;
                let PluginPreparedCapabilityResult::Read(payload) = result else {
                    return Err(Box::new(AgentHarnessError::Unavailable(
                        identity_in_closure.clone(),
                    )) as Box<dyn Error + Send + Sync>);
                };
                serde_json::from_slice::<SessionHarnessStep>(&payload)
                    .map_err(|error| -> Box<dyn Error + Send + Sync> { Box::new(error) })
            });
            return Ok(Some(AgentHarness {
                driver,
                id: identity,
            }));
        }
        Err(AgentHarnessError::Unavailable(name))
    }
}
