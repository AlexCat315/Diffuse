//! Transaction preview, ordered application, exact verification and event outbox.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, simd_length};
use diffuse_observation::cold_log::ObservationBusError;
use diffuse_observation::event_envelope::{
    EventOrigin, EventPayloadRecord, EventPayloadRef, EventProvenance, EventValue,
};
use diffuse_observation::event_kind_registry::EventKindId;
use diffuse_observation::outbox_relay::OutboxRelay;
use diffuse_observation::publisher::{EventDraft, ObservationBus};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::{ComponentEditError, ComponentWriteMode};
use diffuse_scene::components::required_components::ComponentEditFailure;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_extraction::{
    CameraComponent, LightComponent, RenderMeshComponent,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::ComponentRegistryScriptCodec;
use diffuse_sequence::sequence_document::{SequenceDocument, SequenceRevision};

use super::event_components::component_changes;
use super::mutation_components::SceneComponentKey;
use super::transaction_ir::{
    AssetMutation, SceneMutation, SequenceMutation, TransactionApprovalPolicy, TransactionDomain,
    TransactionIR, TransactionOperation, TransactionPreviewResult, TransactionProvenance,
    TransactionVerificationAssertion,
};
use super::world_event::{WorldEvent, WorldPropertyValue};
use crate::planning::edit::{Edit, EditProvenance, WorldRevisionSnapshot};

/// Scenes and sequences have value semantics; registries and buses are shared references.
#[derive(Clone)]
pub struct TransactionExecutionContext {
    pub scene_runtime: Option<SceneRuntime>,
    pub sequence_document: Option<SequenceDocument>,
    pub asset_registry: Option<Arc<AssetRegistry>>,
    pub observation_bus: Option<Arc<ObservationBus>>,
    pub event_origin: EventOrigin,
    pub scene_stream_id: String,
    pub transaction_stream_id: String,
    pub asset_stream_id: String,
    pub ui_stream_id: String,
}

impl TransactionExecutionContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        mut scene_runtime: Option<SceneRuntime>,
        sequence_document: Option<SequenceDocument>,
        asset_registry: Option<Arc<AssetRegistry>>,
        observation_bus: Option<Arc<ObservationBus>>,
        event_origin: EventOrigin,
        scene_stream_id: impl Into<String>,
        transaction_stream_id: impl Into<String>,
        asset_stream_id: impl Into<String>,
        ui_stream_id: impl Into<String>,
    ) -> Self {
        if let Some(scene) = scene_runtime.as_mut() {
            let mut registry = scene.component_registry().clone();
            registry.register_default_script_codec();
            scene.set_component_registry(registry);
        }
        Self {
            scene_runtime,
            sequence_document,
            asset_registry,
            observation_bus,
            event_origin,
            scene_stream_id: scene_stream_id.into(),
            transaction_stream_id: transaction_stream_id.into(),
            asset_stream_id: asset_stream_id.into(),
            ui_stream_id: ui_stream_id.into(),
        }
    }
}

impl Default for TransactionExecutionContext {
    fn default() -> Self {
        Self::new(
            None,
            None,
            None,
            None,
            EventOrigin::tool(None, None),
            "scene:main",
            "transaction",
            "asset:project",
            "ui:confirmation",
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum TransactionExecutorError {
    #[error("missing SceneRuntime in TransactionExecutionContext")]
    MissingSceneRuntime,
    #[error("missing SequenceDocument in TransactionExecutionContext")]
    MissingSequenceDocument,
    #[error("missing AssetRegistry in TransactionExecutionContext")]
    MissingAssetRegistry,
    #[error("asset mutations are not previewable with the current execution context")]
    PreviewUnsupportedForAssets,
    #[error("scene base revision mismatch: expected {expected}, actual {actual}")]
    SceneBaseRevisionMismatch { expected: u64, actual: u64 },
    #[error("sequence base revision mismatch: expected {expected}, actual {}", actual.as_deref().unwrap_or("nil"))]
    SequenceBaseRevisionMismatch {
        expected: String,
        actual: Option<String>,
    },
    #[error("asset base revision mismatch: expected {expected}, actual {}", actual.as_deref().unwrap_or("nil"))]
    AssetBaseRevisionMismatch {
        expected: String,
        actual: Option<String>,
    },
    #[error("invalid entity id: {0}")]
    InvalidEntity(u64),
    #[error("missing component {type_name} on entity {entity_id}")]
    MissingComponent { entity_id: u64, type_name: String },
    #[error("asset load failed at {path}: {message}")]
    AssetLoadFailed { path: String, message: String },
    #[error("transaction verification failed: {0}")]
    VerificationFailed(String),
}

/// Swift's untyped throws preserves the executor, codec and observation error domains.
#[derive(Debug, thiserror::Error)]
pub enum TransactionExecutionError {
    #[error(transparent)]
    Executor(#[from] TransactionExecutorError),
    #[error(transparent)]
    Component(#[from] ComponentEditFailure),
    #[error(transparent)]
    Edit(#[from] ComponentEditError),
    #[error(transparent)]
    Observation(#[from] ObservationBusError),
}

#[derive(Clone, Debug, PartialEq)]
pub struct TransactionApplyResult {
    pub transaction_id: String,
    pub changed_domains: Vec<TransactionDomain>,
    pub created_entity_ids: Vec<u64>,
    pub deleted_entity_ids: Vec<u64>,
    pub scene_revision: Option<u64>,
    pub sequence_revision_id: Option<String>,
    pub asset_entry_count: Option<usize>,
    pub edit: Edit,
    pub world_events: Vec<WorldEvent>,
}

impl TransactionApplyResult {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        transaction_id: impl Into<String>,
        changed_domains: Vec<TransactionDomain>,
        created_entity_ids: Vec<u64>,
        deleted_entity_ids: Vec<u64>,
        scene_revision: Option<u64>,
        sequence_revision_id: Option<String>,
        asset_entry_count: Option<usize>,
        edit: Edit,
        world_events: Vec<WorldEvent>,
    ) -> Self {
        Self {
            transaction_id: transaction_id.into(),
            changed_domains,
            created_entity_ids,
            deleted_entity_ids,
            scene_revision,
            sequence_revision_id,
            asset_entry_count,
            edit,
            world_events,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TransactionExecutor;

impl TransactionExecutor {
    pub fn new() -> Self {
        Self
    }

    pub fn preview(
        &self,
        transaction: &TransactionIR,
        context: &TransactionExecutionContext,
    ) -> Result<TransactionPreviewResult, TransactionExecutionError> {
        if transaction
            .operations
            .iter()
            .any(|operation| matches!(operation, TransactionOperation::Asset(_)))
        {
            return Err(TransactionExecutorError::PreviewUnsupportedForAssets.into());
        }
        let mut preview_context = context.clone();
        preview_context.observation_bus = None;
        let result = self.apply(transaction, &mut preview_context)?;
        Ok(TransactionPreviewResult {
            changed_domains: result.changed_domains,
            created_entity_ids: result.created_entity_ids,
            deleted_entity_ids: result.deleted_entity_ids,
            scene_revision: result.scene_revision,
            sequence_revision_id: result.sequence_revision_id,
            asset_entry_count: result.asset_entry_count,
            mutation_summaries: result.edit.mutation_summaries,
        })
    }

    pub fn apply(
        &self,
        transaction: &TransactionIR,
        context: &mut TransactionExecutionContext,
    ) -> Result<TransactionApplyResult, TransactionExecutionError> {
        let original_scene = context.scene_runtime.clone();
        let original_sequence = context.sequence_document.clone();
        match self.apply_inner(transaction, context, original_scene.as_ref()) {
            Ok(result) => Ok(result),
            Err(error) => {
                context.scene_runtime = original_scene;
                context.sequence_document = original_sequence;
                let _ = self.publish_failure_event(transaction, &error, context);
                Err(error)
            }
        }
    }

    fn apply_inner(
        &self,
        transaction: &TransactionIR,
        context: &mut TransactionExecutionContext,
        original_scene: Option<&SceneRuntime>,
    ) -> Result<TransactionApplyResult, TransactionExecutionError> {
        self.validate(transaction, context)?;
        let revision_before = WorldRevisionSnapshot::new(
            context
                .scene_runtime
                .as_ref()
                .map(|s| s.snapshot().revision),
            context
                .sequence_document
                .as_ref()
                .map(|d| d.revision.id.clone()),
        );
        let mut changed_domains = Vec::new();
        let mut created_entity_ids = Vec::new();
        let mut deleted_entity_ids = Vec::new();
        let mut scene_revision = None;
        let mut sequence_revision_id = None;
        let mut asset_entry_count = None;
        let scene_ops: Vec<_> = transaction
            .operations
            .iter()
            .filter_map(|operation| match operation {
                TransactionOperation::Scene(mutation) => Some(mutation.clone()),
                _ => None,
            })
            .collect();
        if !scene_ops.is_empty() {
            let scene = context
                .scene_runtime
                .as_mut()
                .ok_or(TransactionExecutorError::MissingSceneRuntime)?;
            self.apply_scene(
                &scene_ops,
                transaction,
                scene,
                &mut created_entity_ids,
                &mut deleted_entity_ids,
            )?;
            scene_revision = Some(scene.snapshot().revision);
            changed_domains.push(TransactionDomain::Scene);
        }
        let sequence_ops: Vec<_> = transaction
            .operations
            .iter()
            .filter_map(|operation| match operation {
                TransactionOperation::Sequence(mutation) => Some(mutation),
                _ => None,
            })
            .collect();
        if !sequence_ops.is_empty() {
            let document = context
                .sequence_document
                .as_mut()
                .ok_or(TransactionExecutorError::MissingSequenceDocument)?;
            for mutation in sequence_ops {
                match mutation {
                    SequenceMutation::ReplaceDocument(next) => {
                        *document = self.applied_sequence_document(next, document, transaction)
                    }
                }
            }
            sequence_revision_id = Some(document.revision.id.clone());
            changed_domains.push(TransactionDomain::Sequence);
        }
        let asset_ops: Vec<_> = transaction
            .operations
            .iter()
            .filter_map(|operation| match operation {
                TransactionOperation::Asset(mutation) => Some(mutation),
                _ => None,
            })
            .collect();
        if !asset_ops.is_empty() {
            let registry = context
                .asset_registry
                .as_ref()
                .ok_or(TransactionExecutorError::MissingAssetRegistry)?;
            for mutation in asset_ops {
                match mutation {
                    AssetMutation::ScanProject { root_path } => {
                        let _ = registry.load_project_default(root_path).map_err(|error| {
                            TransactionExecutorError::AssetLoadFailed {
                                path: root_path.clone(),
                                message: error.to_string(),
                            }
                        })?;
                    }
                }
            }
            asset_entry_count = Some(registry.entries_snapshot().len());
            changed_domains.push(TransactionDomain::Asset);
        }
        let revision_after =
            WorldRevisionSnapshot::new(scene_revision, sequence_revision_id.clone());
        let edit = Edit::with_default_id(
            &transaction.id,
            &transaction.summary,
            transaction
                .operations
                .iter()
                .map(|operation| self.operation_summary(operation))
                .collect(),
            changed_domains
                .iter()
                .map(|domain| domain_name(*domain).to_string())
                .collect(),
            EditProvenance::new(transaction.provenance.edit_author_kind()),
            revision_before,
            revision_after,
        );
        let world_events = self.derive_world_events(
            &scene_ops,
            &created_entity_ids,
            context.scene_runtime.as_ref(),
            &edit,
        );
        let result = TransactionApplyResult::new(
            &transaction.id,
            changed_domains,
            created_entity_ids,
            deleted_entity_ids,
            scene_revision,
            sequence_revision_id,
            asset_entry_count,
            edit,
            world_events,
        );
        self.verify(
            &transaction.verification_assertions,
            &result,
            context,
            original_scene,
        )?;
        self.publish_success_events(
            transaction,
            &result,
            &scene_ops,
            context.sequence_document.as_ref(),
            context,
        )?;
        Ok(result)
    }

    fn verify(
        &self,
        assertions: &[TransactionVerificationAssertion],
        result: &TransactionApplyResult,
        context: &TransactionExecutionContext,
        original_scene: Option<&SceneRuntime>,
    ) -> Result<(), TransactionExecutionError> {
        use TransactionVerificationAssertion as Assertion;
        let mut retained_state_indices = BTreeSet::new();
        let mut seen_state_keys = BTreeSet::new();
        let mut superseded_state_keys = BTreeSet::new();
        for (index, assertion) in assertions.iter().enumerate().rev() {
            if let Assertion::SceneState(state) = assertion {
                let key = state.verification_key();
                if !superseded_state_keys.contains(&key) && seen_state_keys.insert(key) {
                    retained_state_indices.insert(index);
                    superseded_state_keys.extend(state.superseded_verification_keys());
                }
            }
        }
        let mut component_checks: BTreeMap<SceneComponentKey, Assertion> = BTreeMap::new();
        let mut normalized_states: BTreeMap<SceneComponentKey, SceneRuntime> = BTreeMap::new();
        for assertion in assertions {
            match assertion {
                Assertion::ComponentData {
                    entity_id,
                    type_id,
                    value,
                    mode,
                } => {
                    let key = SceneComponentKey::new(*entity_id, type_id);
                    let mut value = value.clone();
                    if let Some(scene) = &context.scene_runtime
                        && let Some(normalize) = scene
                            .component_registry()
                            .get(type_id)
                            .and_then(|schema| schema.normalize_changes)
                    {
                        let entity = EntityID::from_raw_value(*entity_id);
                        let baseline = original_scene
                            .filter(|original| original.has_component_by_type_id(type_id, entity))
                            .unwrap_or(scene);
                        let mut expected = normalized_states.get(&key).unwrap_or(baseline).clone();
                        let requested = value.clone();
                        if *mode == ComponentWriteMode::Merge
                            && let Some(previous) = expected.component_data(type_id, entity)
                        {
                            value = normalize(&previous, &value)?;
                        }
                        expected.set_component_data(&requested, type_id, entity, *mode)?;
                        normalized_states.insert(key.clone(), expected);
                    }
                    if *mode == ComponentWriteMode::Merge
                        && let Some(Assertion::ComponentData {
                            value: previous,
                            mode: previous_mode,
                            ..
                        }) = component_checks.get(&key)
                    {
                        let merged = if *previous_mode == ComponentWriteMode::Replace {
                            if let Some(schema) = context
                                .scene_runtime
                                .as_ref()
                                .and_then(|scene| scene.component_registry().get(type_id))
                            {
                                (schema.merge)(previous, &value)?
                            } else {
                                previous.merging(&value)?
                            }
                        } else {
                            previous.merging(&value)?
                        };
                        let previous_mode = *previous_mode;
                        component_checks.insert(
                            key,
                            Assertion::ComponentData {
                                entity_id: *entity_id,
                                type_id: type_id.clone(),
                                value: merged,
                                mode: previous_mode,
                            },
                        );
                    } else {
                        component_checks.insert(
                            key,
                            Assertion::ComponentData {
                                entity_id: *entity_id,
                                type_id: type_id.clone(),
                                value,
                                mode: *mode,
                            },
                        );
                    }
                }
                Assertion::ComponentPresence {
                    entity_id,
                    type_id,
                    is_present,
                } => {
                    let key = SceneComponentKey::new(*entity_id, type_id);
                    if let Some(scene) = &context.scene_runtime
                        && scene
                            .component_registry()
                            .get(type_id)
                            .is_some_and(|schema| schema.normalize_changes.is_some())
                    {
                        let entity = EntityID::from_raw_value(*entity_id);
                        let existed = original_scene
                            .is_some_and(|s| s.has_component_by_type_id(type_id, entity));
                        let baseline = if existed {
                            original_scene.expect("existed requires an original scene")
                        } else {
                            scene
                        };
                        let mut expected = normalized_states.get(&key).unwrap_or(baseline).clone();
                        if *is_present
                            && !existed
                            && !normalized_states.contains_key(&key)
                            && expected.has_component_by_type_id(type_id, entity)
                        {
                            expected.remove_component_data(type_id, entity)?;
                        }
                        if expected.has_component_by_type_id(type_id, entity) != *is_present {
                            if *is_present {
                                expected.add_component(type_id, entity)?;
                            } else {
                                expected.remove_component_data(type_id, entity)?;
                            }
                        }
                        normalized_states.insert(key.clone(), expected);
                    }
                    component_checks.insert(key, assertion.clone());
                }
                _ => {}
            }
        }
        for (key, assertion) in component_checks {
            let scene = context
                .scene_runtime
                .as_ref()
                .ok_or(TransactionExecutorError::MissingSceneRuntime)?;
            let entity = EntityID::from_raw_value(key.entity_id);
            let actual = scene.component_data(&key.type_id, entity);
            let matched = match assertion {
                Assertion::ComponentData {
                    value: expected,
                    mode,
                    ..
                } => {
                    let canonical = normalized_states
                        .get(&key)
                        .and_then(|state| state.component_data(&key.type_id, entity));
                    let normalized = canonical
                        .as_ref()
                        .map(|value| Self::component_expectation(&expected, value))
                        .unwrap_or(expected);
                    if mode == ComponentWriteMode::Merge {
                        actual
                            .as_ref()
                            .is_some_and(|v| v.contains_fields(&normalized))
                    } else {
                        actual.as_ref() == Some(&normalized)
                    }
                }
                Assertion::ComponentPresence { is_present, .. } => actual.is_some() == is_present,
                _ => panic!("Unexpected component assertion"),
            };
            if !matched {
                return Err(TransactionExecutorError::VerificationFailed(format!(
                    "component {} on {} did not match",
                    key.type_id, key.entity_id
                ))
                .into());
            }
        }
        for (index, assertion) in assertions.iter().enumerate() {
            let failure = match assertion {
                Assertion::EntityExists(id) => {
                    if !context
                        .scene_runtime
                        .as_ref()
                        .is_some_and(|scene| scene.contains(EntityID::from_raw_value(*id)))
                    {
                        Some(format!("expected entity {id} to exist"))
                    } else {
                        None
                    }
                }
                Assertion::EntityIsAbsent(id) => {
                    if context
                        .scene_runtime
                        .as_ref()
                        .is_some_and(|scene| scene.contains(EntityID::from_raw_value(*id)))
                    {
                        Some(format!("expected entity {id} to be absent"))
                    } else {
                        None
                    }
                }
                Assertion::CreatedEntityCount(expected) => {
                    if result.created_entity_ids.len() != *expected {
                        Some(format!(
                            "expected {expected} created entities, got {}",
                            result.created_entity_ids.len()
                        ))
                    } else {
                        None
                    }
                }
                Assertion::DeletedEntity(id) => {
                    if !result.deleted_entity_ids.contains(id) {
                        Some(format!("expected entity {id} in the deletion result"))
                    } else {
                        None
                    }
                }
                Assertion::SceneRevisionAdvanced { from } => {
                    if !result.scene_revision.is_some_and(|actual| actual > *from) {
                        Some(format!(
                            "expected scene revision after {from}, got {}",
                            result
                                .scene_revision
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "nil".to_string())
                        ))
                    } else {
                        None
                    }
                }
                Assertion::ComponentData { .. } | Assertion::ComponentPresence { .. } => None,
                Assertion::SceneState(state) => {
                    if !retained_state_indices.contains(&index) {
                        continue;
                    }
                    state.failure_description(
                        context
                            .scene_runtime
                            .as_ref()
                            .ok_or(TransactionExecutorError::MissingSceneRuntime)?,
                    )
                }
            };
            if let Some(failure) = failure {
                return Err(TransactionExecutorError::VerificationFailed(failure).into());
            }
        }
        Ok(())
    }

    fn component_expectation(mask: &ComponentValue, value: &ComponentValue) -> ComponentValue {
        let ComponentValue::Object(fields) = mask else {
            return value.clone();
        };
        ComponentValue::Object(
            fields
                .iter()
                .map(|(key, field)| {
                    let canonical = value
                        .value_at(std::slice::from_ref(key))
                        .map(|value| Self::component_expectation(field, value))
                        .unwrap_or_else(|| field.clone());
                    (key.clone(), canonical)
                })
                .collect(),
        )
    }

    fn apply_scene(
        &self,
        operations: &[SceneMutation],
        transaction: &TransactionIR,
        scene: &mut SceneRuntime,
        created: &mut Vec<u64>,
        deleted: &mut Vec<u64>,
    ) -> Result<(), TransactionExecutionError> {
        for mutation in operations {
            match mutation {
                SceneMutation::SpawnImportedMeshEntity { .. }
                | SceneMutation::SpawnEmptyEntity { .. }
                | SceneMutation::SpawnLightEntity { .. }
                | SceneMutation::SpawnCameraEntity { .. }
                | SceneMutation::DeleteEntity { .. }
                | SceneMutation::DuplicateEntity { .. }
                | SceneMutation::DuplicateEntityWithOffset { .. } => {
                    self.apply_entity_mutation(mutation, scene, created, deleted)?
                }
                SceneMutation::MoveEntity {
                    entity_id,
                    parent_id,
                    index,
                } => {
                    let entity = Self::require_entity(*entity_id, scene)?;
                    let parent = Self::require_optional_entity(*parent_id, scene)?;
                    if !scene.move_entity(entity, parent, *index) {
                        return Err(TransactionExecutorError::InvalidEntity(*entity_id).into());
                    }
                }
                SceneMutation::SetLocalTransform {
                    entity_id,
                    transform,
                } => {
                    let entity = Self::require_entity(*entity_id, scene)?;
                    let _ = scene.set_local_transform(*transform, entity);
                }
                SceneMutation::SetSceneName { entity_id, value } => {
                    let entity = Self::require_entity(*entity_id, scene)?;
                    let _ = scene.set_component(SceneNameComponent::new(value), entity);
                }
                SceneMutation::SetComponentData {
                    entity_id,
                    type_id,
                    value,
                    mode,
                } => {
                    let entity = Self::require_entity(*entity_id, scene)?;
                    scene.set_component_data(value, type_id, entity, *mode)?;
                }
                SceneMutation::AddComponent { entity_id, type_id } => {
                    let entity = Self::require_entity(*entity_id, scene)?;
                    scene.add_component(type_id, entity)?;
                }
                SceneMutation::RemoveComponentData { entity_id, type_id } => {
                    let entity = Self::require_entity(*entity_id, scene)?;
                    scene.remove_component_data(type_id, entity)?;
                }
            }
        }
        scene.propagate_transforms();
        let _ = transaction;
        Ok(())
    }

    fn apply_entity_mutation(
        &self,
        mutation: &SceneMutation,
        scene: &mut SceneRuntime,
        created: &mut Vec<u64>,
        deleted: &mut Vec<u64>,
    ) -> Result<(), TransactionExecutionError> {
        match mutation {
            SceneMutation::SpawnImportedMeshEntity {
                label,
                kind_label,
                mesh_index,
                position,
                parent_id,
            } => {
                let entity = scene.create_entity();
                let _ = scene.set_component(SceneNameComponent::new(label), entity);
                let _ = scene.set_component(SceneKindComponent::new(kind_label), entity);
                let _ =
                    scene.set_local_transform(LocalTransform::from_translation(*position), entity);
                let _ = scene.set_component(
                    RenderMeshComponent::new(*mesh_index, true, Float3::ONE, None, Vec::new()),
                    entity,
                );
                if let Some(parent) = parent_id {
                    let _ = scene.set_parent(Some(EntityID::from_raw_value(*parent)), entity);
                }
                created.push(entity.raw_value());
            }
            SceneMutation::SpawnEmptyEntity {
                label,
                position,
                parent_id,
            } => {
                let entity = scene.create_entity();
                let _ = scene.set_component(SceneNameComponent::new(label), entity);
                let _ = scene.set_component(SceneKindComponent::new("Empty"), entity);
                let _ =
                    scene.set_local_transform(LocalTransform::from_translation(*position), entity);
                if let Some(parent) = parent_id {
                    let _ = scene.set_parent(Some(EntityID::from_raw_value(*parent)), entity);
                }
                created.push(entity.raw_value());
            }
            SceneMutation::SpawnLightEntity {
                label,
                light_type,
                position,
                initial_intensity,
                initial_color,
                initial_range,
                initial_cast_shadows,
                parent_id,
            } => {
                let entity = scene.create_entity();
                let _ = scene.set_component(SceneNameComponent::new(label), entity);
                let _ = scene.set_component(SceneKindComponent::new("Light"), entity);
                scene.add_component("light", entity)?;
                let _ = scene.update_component::<LightComponent>(entity, |light| {
                    light.light_type = *light_type;
                    if let Some(v) = initial_intensity {
                        light.intensity = *v;
                    }
                    if let Some(v) = initial_color {
                        light.color = *v;
                    }
                    if let Some(v) = initial_range {
                        light.range = *v;
                    }
                    if let Some(v) = initial_cast_shadows {
                        light.cast_shadows = *v;
                    }
                });
                let _ =
                    scene.set_local_transform(LocalTransform::from_translation(*position), entity);
                if let Some(parent) = parent_id {
                    let _ = scene.set_parent(Some(EntityID::from_raw_value(*parent)), entity);
                }
                created.push(entity.raw_value());
            }
            SceneMutation::SpawnCameraEntity {
                label,
                position,
                initial_fov_y_degrees,
                parent_id,
            } => {
                let entity = scene.create_entity();
                let _ = scene.set_component(SceneNameComponent::new(label), entity);
                let _ = scene.set_component(SceneKindComponent::new("Camera"), entity);
                scene.add_component("camera", entity)?;
                if let Some(fov) = initial_fov_y_degrees {
                    let _ = scene.update_component::<CameraComponent>(entity, |camera| {
                        camera.fov_y_radians = *fov * std::f32::consts::PI / 180.0
                    });
                }
                let _ =
                    scene.set_local_transform(LocalTransform::from_translation(*position), entity);
                if let Some(parent) = parent_id {
                    let _ = scene.set_parent(Some(EntityID::from_raw_value(*parent)), entity);
                }
                created.push(entity.raw_value());
            }
            SceneMutation::DeleteEntity { entity_id } => {
                let entity = Self::require_entity(*entity_id, scene)?;
                if !scene.destroy_entity(entity) {
                    return Err(TransactionExecutorError::InvalidEntity(*entity_id).into());
                }
                deleted.push(*entity_id);
            }
            SceneMutation::DuplicateEntity { entity_id } => {
                let source = Self::require_entity(*entity_id, scene)?;
                created.push(Self::duplicate_entity(source, None, scene).raw_value());
            }
            SceneMutation::DuplicateEntityWithOffset {
                entity_id,
                position_offset,
            } => {
                let source = Self::require_entity(*entity_id, scene)?;
                created.push(
                    Self::duplicate_entity(source, Some(*position_offset), scene).raw_value(),
                );
            }
            _ => panic!("non-entity mutation routed to applyEntityMutation"),
        }
        Ok(())
    }

    fn duplicate_entity(
        source: EntityID,
        offset: Option<Float3>,
        scene: &mut SceneRuntime,
    ) -> EntityID {
        let entity = scene.create_entity();
        if let Some(name) = scene.component::<SceneNameComponent>(source) {
            let _ = scene.set_component(SceneNameComponent::new(name.value + " Copy"), entity);
        }
        if let Some(kind) = scene.component::<SceneKindComponent>(source) {
            let _ = scene.set_component(kind, entity);
        }
        if let Some(local) = scene.local_transform(source) {
            let _ = scene.set_local_transform(local, entity);
        }
        if let Some(offset) = offset {
            let mut transform = scene.local_transform(source).unwrap_or_default();
            transform.matrix.columns[3] += Float4::new(offset.x, offset.y, offset.z, 0.0);
            let _ = scene.set_local_transform(transform, entity);
        }
        if let Some(parent) = scene.parent(source) {
            let _ = scene.set_parent(Some(parent), entity);
        }
        scene.duplicate_component_data(source, entity);
        entity
    }

    fn require_entity(
        raw_id: u64,
        scene: &SceneRuntime,
    ) -> Result<EntityID, TransactionExecutorError> {
        let entity = EntityID::from_raw_value(raw_id);
        if !scene.contains(entity) {
            return Err(TransactionExecutorError::InvalidEntity(raw_id));
        }
        Ok(entity)
    }

    fn require_optional_entity(
        raw_id: Option<u64>,
        scene: &SceneRuntime,
    ) -> Result<Option<EntityID>, TransactionExecutorError> {
        raw_id.map(|id| Self::require_entity(id, scene)).transpose()
    }

    fn applied_sequence_document(
        &self,
        next: &SequenceDocument,
        previous: &SequenceDocument,
        transaction: &TransactionIR,
    ) -> SequenceDocument {
        let mut document = next.clone();
        let mut revision = SequenceRevision::generate();
        revision.parent_id = Some(previous.revision.id.clone());
        revision.author = transaction
            .intent
            .as_ref()
            .map(|intent| match intent.source {
                crate::planning::intent_ir::IntentSource::Human => "human",
                crate::planning::intent_ir::IntentSource::Ai => "ai",
                crate::planning::intent_ir::IntentSource::System => "system",
            })
            .unwrap_or("system")
            .to_string();
        revision.base_scene_revision_id = document
            .revision
            .base_scene_revision_id
            .clone()
            .or_else(|| previous.revision.base_scene_revision_id.clone());
        revision.base_sequence_revision_id = Some(previous.revision.id.clone());
        revision.transaction_ids = previous.revision.transaction_ids.clone();
        revision.transaction_ids.push(transaction.id.clone());
        document.revision = revision;
        document
    }

    fn publish_success_events(
        &self,
        transaction: &TransactionIR,
        result: &TransactionApplyResult,
        scene_ops: &[SceneMutation],
        sequence_document: Option<&SequenceDocument>,
        context: &TransactionExecutionContext,
    ) -> Result<(), ObservationBusError> {
        let Some(bus) = &context.observation_bus else {
            return Ok(());
        };
        let relay = OutboxRelay::new();
        let enqueue = |kind, stream_id: &str, payload| {
            let mut draft = EventDraft::new(
                kind,
                stream_id,
                context.event_origin.clone(),
                event_provenance(transaction.provenance),
                EventPayloadRef::Inline { record: payload },
            );
            draft.causation_id = Some(transaction.id.clone());
            relay.enqueue(draft);
        };
        enqueue(
            EventKindId::TransactionApplied,
            &context.transaction_stream_id,
            self.transaction_lifecycle_payload(
                transaction,
                "applied",
                &result.changed_domains,
                result.scene_revision,
                result.sequence_revision_id.as_deref(),
                result.asset_entry_count,
                None,
            ),
        );
        if result.changed_domains.contains(&TransactionDomain::Scene) {
            let entity_ids = self.changed_entity_ids(
                scene_ops,
                &result.created_entity_ids,
                &result.deleted_entity_ids,
            );
            enqueue(
                EventKindId::SceneChanged,
                &context.scene_stream_id,
                self.scene_changed_payload(&transaction.id, &entity_ids, result.scene_revision),
            );
            if !result.created_entity_ids.is_empty() {
                enqueue(
                    EventKindId::SceneEntityAdded,
                    &context.scene_stream_id,
                    self.scene_entity_payload(&result.created_entity_ids, result.scene_revision),
                );
            }
            if !result.deleted_entity_ids.is_empty() {
                enqueue(
                    EventKindId::SceneEntityRemoved,
                    &context.scene_stream_id,
                    self.scene_entity_payload(&result.deleted_entity_ids, result.scene_revision),
                );
            }
        }
        if result
            .changed_domains
            .contains(&TransactionDomain::Sequence)
        {
            enqueue(
                EventKindId::SequenceChanged,
                &format!(
                    "sequence:{}",
                    sequence_document.map(|d| d.id.as_str()).unwrap_or("main")
                ),
                self.sequence_changed_payload(sequence_document, &transaction.id),
            );
        }
        if result.changed_domains.contains(&TransactionDomain::Asset) {
            enqueue(
                EventKindId::AssetImportFinished,
                &context.asset_stream_id,
                self.asset_import_payload(
                    result.asset_entry_count,
                    &transaction.id,
                    context
                        .asset_registry
                        .as_ref()
                        .and_then(|r| r.current_project_root())
                        .as_deref(),
                ),
            );
        }
        let _ = relay.flush(bus)?;
        Ok(())
    }

    fn publish_failure_event(
        &self,
        transaction: &TransactionIR,
        error: &TransactionExecutionError,
        context: &TransactionExecutionContext,
    ) -> Result<(), ObservationBusError> {
        let Some(bus) = &context.observation_bus else {
            return Ok(());
        };
        let payload = self.transaction_lifecycle_payload(
            transaction,
            "failed",
            &[],
            None,
            None,
            None,
            Some(&error.to_string()),
        );
        let _ = bus.publish(
            EventKindId::TransactionFailed,
            &context.transaction_stream_id,
            EventPayloadRef::Inline { record: payload },
            context.event_origin.clone(),
            None,
            Some(transaction.id.clone()),
            None,
            event_provenance(transaction.provenance),
            1,
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn transaction_lifecycle_payload(
        &self,
        transaction: &TransactionIR,
        status: &str,
        changed_domains: &[TransactionDomain],
        scene_revision: Option<u64>,
        sequence_revision_id: Option<&str>,
        asset_entry_count: Option<usize>,
        message: Option<&str>,
    ) -> EventPayloadRecord {
        let mut payload = BTreeMap::from([
            (
                "transaction_id".to_string(),
                EventValue::String(transaction.id.clone()),
            ),
            (
                "summary".to_string(),
                EventValue::String(transaction.summary.clone()),
            ),
            ("status".to_string(), EventValue::String(status.to_string())),
            (
                "approval_policy".to_string(),
                EventValue::String(approval_policy_name(transaction.approval_policy).to_string()),
            ),
            (
                "provenance".to_string(),
                EventValue::String(provenance_name(transaction.provenance).to_string()),
            ),
            (
                "changed_domains".to_string(),
                EventValue::Array(
                    changed_domains
                        .iter()
                        .map(|domain| EventValue::String(domain_name(*domain).to_string()))
                        .collect(),
                ),
            ),
        ]);
        if let Some(revision) = scene_revision {
            payload.insert("scene_revision".to_string(), integer(revision));
        }
        if let Some(revision) = sequence_revision_id {
            payload.insert(
                "sequence_revision_id".to_string(),
                EventValue::String(revision.to_string()),
            );
        }
        if let Some(count) = asset_entry_count {
            payload.insert("asset_entry_count".to_string(), integer(count as u64));
        }
        if let Some(message) = message {
            payload.insert(
                "message".to_string(),
                EventValue::String(message.to_string()),
            );
        }
        payload
    }

    fn scene_changed_payload(
        &self,
        transaction_id: &str,
        entity_ids: &[u64],
        revision: Option<u64>,
    ) -> EventPayloadRecord {
        let mut payload = self.scene_entity_payload(entity_ids, revision);
        payload.insert(
            "transaction_id".to_string(),
            EventValue::String(transaction_id.to_string()),
        );
        payload
    }

    fn scene_entity_payload(
        &self,
        entity_ids: &[u64],
        revision: Option<u64>,
    ) -> EventPayloadRecord {
        let mut payload = BTreeMap::from([(
            "entity_ids".to_string(),
            EventValue::Array(entity_ids.iter().map(|&id| integer(id)).collect()),
        )]);
        if let Some(revision) = revision {
            payload.insert("scene_revision".to_string(), integer(revision));
        }
        payload
    }

    fn sequence_changed_payload(
        &self,
        document: Option<&SequenceDocument>,
        transaction_id: &str,
    ) -> EventPayloadRecord {
        let mut payload = BTreeMap::from([(
            "transaction_id".to_string(),
            EventValue::String(transaction_id.to_string()),
        )]);
        if let Some(document) = document {
            payload.insert(
                "sequence_id".to_string(),
                EventValue::String(document.id.clone()),
            );
            payload.insert(
                "sequence_revision_id".to_string(),
                EventValue::String(document.revision.id.clone()),
            );
            payload.insert(
                "shot_count".to_string(),
                integer(document.shots.len() as u64),
            );
        }
        payload
    }

    fn asset_import_payload(
        &self,
        entry_count: Option<usize>,
        transaction_id: &str,
        project_root: Option<&str>,
    ) -> EventPayloadRecord {
        let mut payload = BTreeMap::from([(
            "transaction_id".to_string(),
            EventValue::String(transaction_id.to_string()),
        )]);
        if let Some(count) = entry_count {
            payload.insert("entry_count".to_string(), integer(count as u64));
        }
        if let Some(root) = project_root {
            payload.insert(
                "project_root".to_string(),
                EventValue::String(root.to_string()),
            );
        }
        payload
    }

    fn changed_entity_ids(
        &self,
        scene_ops: &[SceneMutation],
        created: &[u64],
        deleted: &[u64],
    ) -> Vec<u64> {
        let mut ids: BTreeSet<_> = created.iter().chain(deleted).copied().collect();
        ids.extend(scene_ops.iter().filter_map(SceneMutation::entity_id));
        ids.into_iter().collect()
    }

    fn operation_summary(&self, operation: &TransactionOperation) -> String {
        match operation {
            TransactionOperation::Scene(mutation) => self.scene_mutation_summary(mutation),
            TransactionOperation::Sequence(_) => "sequence:replace".to_string(),
            TransactionOperation::Asset(AssetMutation::ScanProject { root_path }) => {
                format!("asset:scan:{root_path}")
            }
        }
    }

    fn scene_mutation_summary(&self, mutation: &SceneMutation) -> String {
        match mutation {
            SceneMutation::SpawnImportedMeshEntity { label, .. } => format!("scene:spawn:{label}"),
            SceneMutation::SpawnEmptyEntity { label, .. } => format!("scene:spawn_empty:{label}"),
            SceneMutation::SpawnLightEntity { label, .. } => format!("scene:spawn_light:{label}"),
            SceneMutation::SpawnCameraEntity { label, .. } => format!("scene:spawn_camera:{label}"),
            SceneMutation::DeleteEntity { entity_id } => format!("scene:delete:{entity_id}"),
            SceneMutation::DuplicateEntity { entity_id } => format!("scene:duplicate:{entity_id}"),
            SceneMutation::DuplicateEntityWithOffset { entity_id, .. } => {
                format!("scene:duplicate_offset:{entity_id}")
            }
            SceneMutation::MoveEntity { entity_id, .. } => format!("scene:move:{entity_id}"),
            SceneMutation::SetLocalTransform { entity_id, .. } => {
                format!("scene:transform:{entity_id}")
            }
            SceneMutation::SetSceneName { entity_id, value } => {
                format!("scene:rename:{entity_id}:{value}")
            }
            SceneMutation::SetComponentData {
                entity_id, type_id, ..
            } => format!("scene:component:{type_id}:{entity_id}"),
            SceneMutation::AddComponent { entity_id, type_id } => {
                format!("scene:add_component:{type_id}:{entity_id}")
            }
            SceneMutation::RemoveComponentData { entity_id, type_id } => {
                format!("scene:remove_component:{type_id}:{entity_id}")
            }
        }
    }

    fn derive_world_events(
        &self,
        scene_ops: &[SceneMutation],
        created: &[u64],
        scene: Option<&SceneRuntime>,
        edit: &Edit,
    ) -> Vec<WorldEvent> {
        let mut events = Vec::new();
        let mut created_index = 0;
        for operation in scene_ops {
            match operation {
                SceneMutation::SpawnImportedMeshEntity {
                    label,
                    kind_label: _,
                    position,
                    parent_id,
                    ..
                }
                | SceneMutation::SpawnEmptyEntity {
                    label,
                    position,
                    parent_id,
                }
                | SceneMutation::SpawnLightEntity {
                    label,
                    position,
                    parent_id,
                    ..
                }
                | SceneMutation::SpawnCameraEntity {
                    label,
                    position,
                    parent_id,
                    ..
                } => {
                    if created_index < created.len() {
                        let id = created[created_index];
                        let reference = format!("scene:{id}");
                        let (kind, component_id) = match operation {
                            SceneMutation::SpawnImportedMeshEntity { kind_label, .. } => {
                                (kind_label.as_str(), None)
                            }
                            SceneMutation::SpawnEmptyEntity { .. } => ("Empty", None),
                            SceneMutation::SpawnLightEntity { .. } => ("Light", Some("light")),
                            SceneMutation::SpawnCameraEntity { .. } => ("Camera", Some("camera")),
                            _ => unreachable!("only spawn mutations enter this branch"),
                        };
                        events.push(WorldEvent::EntityAdded {
                            ref_: reference.clone(),
                            name: label.clone(),
                            kind: Some(kind.to_string()),
                        });
                        events.push(authored(&reference, "position", vector_property(*position)));
                        if let Some(type_id) = component_id
                            && let Some(data) = scene.and_then(|scene| {
                                scene.component_data(type_id, EntityID::from_raw_value(id))
                            })
                        {
                            events.extend(component_changes(id, type_id, &data));
                        }
                        if let Some(parent) = parent_id {
                            events.push(authored(
                                &reference,
                                "parentRef",
                                WorldPropertyValue::String(format!("scene:{parent}")),
                            ));
                        }
                        events.extend(self.world_transform_events(id, scene));
                        created_index += 1;
                    }
                }
                SceneMutation::DeleteEntity { entity_id } => {
                    events.push(WorldEvent::EntityRemoved {
                        ref_: format!("scene:{entity_id}"),
                    })
                }
                SceneMutation::DuplicateEntity { .. }
                | SceneMutation::DuplicateEntityWithOffset { .. } => {
                    if created_index < created.len()
                        && let Some(scene) = scene
                    {
                        let id = created[created_index];
                        let reference = format!("scene:{id}");
                        let entity = EntityID::from_raw_value(id);
                        let name = scene
                            .component::<SceneNameComponent>(entity)
                            .map(|name| name.value)
                            .unwrap_or_default();
                        let kind = scene
                            .component::<SceneKindComponent>(entity)
                            .map(|kind| kind.value);
                        events.push(WorldEvent::EntityAdded {
                            ref_: reference.clone(),
                            name,
                            kind,
                        });
                        if let Some(transform) = scene.local_transform(entity) {
                            events.push(authored(
                                &reference,
                                "position",
                                vector_property(transform.translation()),
                            ));
                        }
                        events.extend(self.world_transform_events(id, Some(scene)));
                        created_index += 1;
                    }
                }
                SceneMutation::MoveEntity {
                    entity_id,
                    parent_id,
                    ..
                } => {
                    events.push(authored(
                        &format!("scene:{entity_id}"),
                        "parentRef",
                        WorldPropertyValue::String(
                            parent_id
                                .map(|id| format!("scene:{id}"))
                                .unwrap_or_default(),
                        ),
                    ));
                    events.extend(self.world_transform_events(*entity_id, scene));
                }
                SceneMutation::SetLocalTransform {
                    entity_id,
                    transform,
                } => {
                    let reference = format!("scene:{entity_id}");
                    events.push(authored(
                        &reference,
                        "position",
                        vector_property(transform.translation()),
                    ));
                    let euler = self.extract_euler_xyz_degrees(transform.matrix);
                    let is_zero_rotation =
                        euler.x.abs() < 0.01 && euler.y.abs() < 0.01 && euler.z.abs() < 0.01;
                    if !is_zero_rotation {
                        events.push(authored(&reference, "eulerDegrees", vector_property(euler)));
                    }
                    let scale = self.extract_scale(transform.matrix);
                    let is_unit = (scale.x - 1.0).abs() < 0.0001
                        && (scale.y - 1.0).abs() < 0.0001
                        && (scale.z - 1.0).abs() < 0.0001;
                    if !is_unit {
                        events.push(authored(&reference, "scale", vector_property(scale)));
                    }
                    events.extend(self.world_transform_events(*entity_id, scene));
                }
                SceneMutation::SetSceneName { entity_id, value } => events.push(authored(
                    &format!("scene:{entity_id}"),
                    "name",
                    WorldPropertyValue::String(value.clone()),
                )),
                SceneMutation::SetComponentData {
                    entity_id, type_id, ..
                }
                | SceneMutation::AddComponent { entity_id, type_id }
                | SceneMutation::RemoveComponentData { entity_id, type_id } => {
                    let entity = EntityID::from_raw_value(*entity_id);
                    let dependencies = scene
                        .and_then(|scene| scene.component_registry().required_schemas(type_id).ok())
                        .unwrap_or_default();
                    let type_ids = std::iter::once(type_id.clone()).chain(
                        dependencies
                            .into_iter()
                            .filter(|schema| !schema.is_structural)
                            .map(|schema| schema.type_id),
                    );
                    for id in type_ids {
                        let data = scene
                            .and_then(|scene| scene.component_data(&id, entity))
                            .unwrap_or(ComponentValue::Null);
                        events.extend(component_changes(*entity_id, &id, &data));
                    }
                }
            }
        }
        events.push(WorldEvent::EditApplied {
            edit_id: edit.id.clone(),
            summary: edit.summary.clone(),
            revision: edit.revision_after.scene_revision.unwrap_or(0),
        });
        events
    }

    fn world_transform_events(
        &self,
        entity_id: u64,
        scene: Option<&SceneRuntime>,
    ) -> Vec<WorldEvent> {
        let Some(scene) = scene else {
            return Vec::new();
        };
        let Some(world_transform) = scene.world_transform(EntityID::from_raw_value(entity_id))
        else {
            return Vec::new();
        };
        let reference = format!("scene:{entity_id}");
        let evaluated = |property: &str, value| WorldEvent::EntityEvaluatedChanged {
            ref_: reference.clone(),
            property: property.to_string(),
            value,
        };
        let mut events = vec![evaluated(
            "worldPosition",
            vector_property(world_transform.translation()),
        )];
        let euler = self.extract_euler_xyz_degrees(world_transform.matrix);
        if euler.x.abs() >= 0.01 || euler.y.abs() >= 0.01 || euler.z.abs() >= 0.01 {
            events.push(evaluated("worldEulerDegrees", vector_property(euler)));
        }
        let scale = self.extract_scale(world_transform.matrix);
        if (scale.x - 1.0).abs() >= 0.001
            || (scale.y - 1.0).abs() >= 0.001
            || (scale.z - 1.0).abs() >= 0.001
        {
            events.push(evaluated("worldScale", vector_property(scale)));
        }
        events
    }

    fn extract_euler_xyz_degrees(&self, matrix: Float4x4) -> Float3 {
        let sx = simd_length(matrix.columns[0].xyz());
        let sy = simd_length(matrix.columns[1].xyz());
        let sz = simd_length(matrix.columns[2].xyz());
        if !(sx > 0.0 && sy > 0.0 && sz > 0.0) {
            return Float3::ZERO;
        }
        let r02 = matrix.columns[2].x / sz;
        let r12 = matrix.columns[2].y / sz;
        let r22 = matrix.columns[2].z / sz;
        let r01 = matrix.columns[1].x / sy;
        let r00 = matrix.columns[0].x / sx;
        // Swift `Float.maximum(-1, Float.minimum(1, r02))` keeps IEEE
        // minimum/maximum semantics: a NaN input yields the other operand.
        // `clamp` would propagate NaN instead.
        #[allow(clippy::manual_clamp)]
        let sin_beta = r02.min(1.0).max(-1.0);
        let beta = sin_beta.asin();
        let to_degrees = 180.0 / std::f32::consts::PI;
        if sin_beta.abs() < 0.9999 {
            Float3::new(
                (-r12).atan2(r22) * to_degrees,
                beta * to_degrees,
                (-r01).atan2(r00) * to_degrees,
            )
        } else {
            let r10 = matrix.columns[0].y / sx;
            let r11 = matrix.columns[1].y / sy;
            Float3::new(r10.atan2(r11) * to_degrees, beta * to_degrees, 0.0)
        }
    }

    fn extract_scale(&self, matrix: Float4x4) -> Float3 {
        Float3::new(
            simd_length(matrix.columns[0].xyz()),
            simd_length(matrix.columns[1].xyz()),
            simd_length(matrix.columns[2].xyz()),
        )
    }

    fn validate(
        &self,
        transaction: &TransactionIR,
        context: &TransactionExecutionContext,
    ) -> Result<(), TransactionExecutorError> {
        let domains: BTreeSet<_> = transaction
            .operations
            .iter()
            .map(TransactionOperation::domain)
            .collect();
        if domains.contains(&TransactionDomain::Scene)
            && let Some(expected) = transaction.base_revisions.scene_revision
        {
            let actual = context
                .scene_runtime
                .as_ref()
                .ok_or(TransactionExecutorError::MissingSceneRuntime)?
                .snapshot()
                .revision;
            if actual != expected {
                return Err(TransactionExecutorError::SceneBaseRevisionMismatch {
                    expected,
                    actual,
                });
            }
        }
        if domains.contains(&TransactionDomain::Sequence)
            && let Some(expected) = &transaction.base_revisions.sequence_revision_id
        {
            let actual = &context
                .sequence_document
                .as_ref()
                .ok_or(TransactionExecutorError::MissingSequenceDocument)?
                .revision
                .id;
            if actual != expected {
                return Err(TransactionExecutorError::SequenceBaseRevisionMismatch {
                    expected: expected.clone(),
                    actual: Some(actual.clone()),
                });
            }
        }
        if domains.contains(&TransactionDomain::Asset)
            && let Some(expected) = &transaction.base_revisions.asset_revision_id
        {
            let registry = context
                .asset_registry
                .as_ref()
                .ok_or(TransactionExecutorError::MissingAssetRegistry)?;
            let actual = registry.current_project_root();
            if actual.as_ref() != Some(expected) {
                return Err(TransactionExecutorError::AssetBaseRevisionMismatch {
                    expected: expected.clone(),
                    actual,
                });
            }
        }
        Ok(())
    }
}

pub(crate) fn domain_name(domain: TransactionDomain) -> &'static str {
    match domain {
        TransactionDomain::Scene => "scene",
        TransactionDomain::Sequence => "sequence",
        TransactionDomain::Asset => "asset",
    }
}

fn approval_policy_name(policy: TransactionApprovalPolicy) -> &'static str {
    match policy {
        TransactionApprovalPolicy::Automatic => "automatic",
        TransactionApprovalPolicy::RequiresApproval => "requiresApproval",
        TransactionApprovalPolicy::Forbidden => "forbidden",
    }
}

fn provenance_name(provenance: TransactionProvenance) -> &'static str {
    match provenance {
        TransactionProvenance::Authored => "authored",
        TransactionProvenance::Inferred => "inferred",
        TransactionProvenance::Proposal => "proposal",
        TransactionProvenance::Baked => "baked",
    }
}

fn event_provenance(provenance: TransactionProvenance) -> EventProvenance {
    match provenance {
        TransactionProvenance::Authored => EventProvenance::Authored,
        TransactionProvenance::Inferred => EventProvenance::Inferred,
        TransactionProvenance::Proposal => EventProvenance::Evaluated,
        TransactionProvenance::Baked => EventProvenance::Baked,
    }
}

pub(crate) fn integer(value: u64) -> EventValue {
    EventValue::Integer(i64::try_from(value).expect("value must fit Swift Int64"))
}

fn vector_property(value: Float3) -> WorldPropertyValue {
    WorldPropertyValue::Vec3(value.x, value.y, value.z)
}

fn authored(reference: &str, property: &str, value: WorldPropertyValue) -> WorldEvent {
    WorldEvent::EntityAuthoredChanged {
        ref_: reference.to_string(),
        property: property.to_string(),
        value,
    }
}
