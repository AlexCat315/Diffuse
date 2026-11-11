//! `Editor/Sources/EditorCore/Scene/Adapter/Transactions.swift`.

use std::collections::BTreeSet;

use diffuse_intent::planning::intent_ir::{IntentIR, IntentSource};
use diffuse_intent::transactions::mutation_components::SceneComponentKey;
use diffuse_intent::transactions::transaction_executor::{
    TransactionApplyResult, TransactionExecutionContext,
};
use diffuse_intent::transactions::transaction_ir::{
    SceneMutation, TransactionBaseRevisions, TransactionIR, TransactionOperation,
    TransactionProvenance,
};
use diffuse_observation::event_envelope::EventOrigin;
use diffuse_scene::entity_id::{EntityID, RuntimeComponent};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

impl EditorSceneAdapter {
    pub fn set_component_data<Component: RuntimeComponent>(
        &self,
        component: Component,
        entity: EntityID,
    ) -> bool {
        let registry = self.scene().component_registry().clone();
        let Some(schema) = registry.schema_for::<Component>() else {
            return false;
        };
        let type_id = schema.type_id.clone();
        let display_name = schema.display_name.clone();
        let mut prepared = self.scene();
        if !prepared.set_component(component, entity) {
            return false;
        }
        let Some(value) = prepared.component_data(&type_id, entity) else {
            return false;
        };
        self.apply_scene_transaction(
            "scene.set_component_data",
            format!("Update {display_name}"),
            vec![entity.raw_value()],
            vec![SceneMutation::SetComponentData {
                entity_id: entity.raw_value(),
                type_id,
                value,
                mode: diffuse_scene::components::editing::ComponentWriteMode::Replace,
            }],
        )
        .is_some()
    }

    pub fn update_component_data<Component: RuntimeComponent>(
        &self,
        entity: EntityID,
        update: impl FnOnce(&mut Component),
    ) -> bool {
        let Some(mut component) = self.scene().component::<Component>(entity) else {
            return false;
        };
        update(&mut component);
        self.set_component_data(component, entity)
    }

    /// Swift's `targetRawIDs: [UInt64] = []` default is supplied by
    /// [`Self::apply_scene_transaction_default`].
    pub fn apply_scene_transaction(
        &self,
        intent_verb: &str,
        summary: impl Into<String>,
        target_raw_ids: Vec<u64>,
        mutations: Vec<SceneMutation>,
    ) -> Option<TransactionApplyResult> {
        let summary = summary.into();
        if !self.is_authoring_enabled() {
            self.notify_transaction_error(&format!(
                "{summary}: stop simulation before editing the scene"
            ));
            return None;
        }
        let locked_targets: Vec<u64> = target_raw_ids
            .iter()
            .copied()
            .filter(|raw_id| self.is_entity_locked(*raw_id))
            .collect();
        if !locked_targets.is_empty() {
            let joined = locked_targets
                .iter()
                .map(|raw_id| raw_id.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            self.notify_transaction_error(&format!("{summary}: entity is locked ({joined})"));
            return None;
        }
        let mut intent = IntentIR::new(intent_verb, &summary, IntentSource::Human);
        intent.target_object_ids = target_raw_ids
            .iter()
            .map(|raw_id| format!("scene:{raw_id}"))
            .collect();
        let operations: Vec<TransactionOperation> = mutations
            .iter()
            .cloned()
            .map(TransactionOperation::Scene)
            .collect();
        let scene_revision = self.revision();
        let mut transaction =
            TransactionIR::new(&summary, operations, TransactionProvenance::Authored);
        transaction.intent = Some(intent);
        transaction.base_revisions = TransactionBaseRevisions::new();
        transaction.base_revisions.scene_revision = Some(scene_revision);
        let mut context = TransactionExecutionContext::new(
            Some(self.scene()),
            None,
            None,
            None,
            EventOrigin::tool(None, None),
            "scene:main",
            "transaction",
            "asset:project",
            "ui:confirmation",
        );
        let result = match self.transaction_executor.apply(&transaction, &mut context) {
            Ok(result) => result,
            Err(error) => {
                self.notify_transaction_error(&format!("{summary}: {error}"));
                return None;
            }
        };
        let Some(updated_scene) = context.scene_runtime.take() else {
            self.notify_transaction_error(&format!(
                "{summary}: transaction completed without a scene result"
            ));
            return None;
        };
        self.set_scene(updated_scene);
        let keys: Vec<SceneComponentKey> = mutations
            .iter()
            .filter_map(SceneMutation::component_key)
            .collect();
        let component_keys: Option<BTreeSet<SceneComponentKey>> = if keys.len() == mutations.len() {
            Some(keys.into_iter().collect())
        } else {
            None
        };
        self.notify_revision_changed(true, component_keys);
        Some(result)
    }

    /// Swift's `targetRawIDs: []` default.
    pub fn apply_scene_transaction_default(
        &self,
        intent_verb: &str,
        summary: impl Into<String>,
        mutations: Vec<SceneMutation>,
    ) -> Option<TransactionApplyResult> {
        self.apply_scene_transaction(intent_verb, summary, Vec::new(), mutations)
    }
}
