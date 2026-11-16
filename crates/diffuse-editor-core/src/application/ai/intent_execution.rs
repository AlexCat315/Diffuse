//! `Editor/Sources/EditorCore/Application/AI/IntentExecution.swift` (selected helpers).
//!
//! The full IntentExecution extension also defines `submitSpawnEntityIntent`,
//! `submitResolvedIntent`, `applyInvocationResult`, `makeExecutionContext` and
//! friends; those are ported incrementally alongside the AI request pipeline.

use diffuse_intent::invocation::capability_invocation_planning::CapabilityInvocationContext;
use diffuse_intent::planning::intent_ir::{IntentEvidence, IntentSource};
use diffuse_intent::transactions::transaction_executor::TransactionExecutionContext;
use diffuse_observation::event_envelope::EventOrigin;
use diffuse_scene::entity_id::EntityID;

use crate::application::editor_application::EditorApplication;
use crate::state::editor_state::PlaybackState;

impl EditorApplication {
    /// `entityID(from:)` — reconstructs an `EntityID` from its packed `UInt64`
    /// (`index` in the low 32 bits, `generation` in the high 32 bits).
    pub(crate) fn entity_id(&self, raw_id: Option<u64>) -> Option<EntityID> {
        raw_id.map(|raw| EntityID::new((raw & 0xFFFF_FFFF) as u32, (raw >> 32) as u32))
    }

    /// `prefix(_:bytes:)` — the longest UTF-8 prefix of `text` within `bytes`
    /// bytes that does not split a scalar.
    pub(crate) fn prefix(text: &str, bytes: usize) -> String {
        if text.len() <= bytes {
            return text.to_string();
        }
        let mut cut = bytes;
        while cut > 0 {
            if std::str::from_utf8(&text.as_bytes()[..cut]).is_ok() {
                return text[..cut].to_string();
            }
            cut -= 1;
        }
        String::new()
    }

    /// `makeCapabilityInvocationContext(defaultSource:defaultConfidence:defaultEvidence:)`
    /// — selects the authoring target and wraps the live scene runtime.
    pub(crate) fn make_capability_invocation_context(
        &self,
        default_source: IntentSource,
        default_confidence: f64,
        default_evidence: Vec<IntentEvidence>,
    ) -> CapabilityInvocationContext {
        let selected_entity_id = if default_source == IntentSource::Ai {
            self.agent_task_service
                .borrow()
                .active_task()
                .and_then(|task| task.target.primary_entity_id)
        } else {
            self.store.selected_entity_id()
        };
        let scene_runtime = self.scene.scene();
        CapabilityInvocationContext::from_scene_runtime(
            &scene_runtime,
            selected_entity_id,
            self.store.playback_state() == PlaybackState::Stopped,
            default_source,
            default_confidence,
            default_evidence,
        )
    }

    /// `makeExecutionContext()` — builds the transaction-execution context that
    /// records observations under the document identity for the AI actor.
    pub(crate) fn make_execution_context(&self) -> TransactionExecutionContext {
        let scene_runtime = self.scene.scene();
        let identity = self.store.state().document.identity.to_string();
        TransactionExecutionContext::new(
            Some(scene_runtime),
            None,
            None,
            Some(self.observation_bus.clone()),
            EventOrigin::tool(None, None),
            identity.clone(),
            identity.clone(),
            identity.clone(),
            identity,
        )
    }
}
