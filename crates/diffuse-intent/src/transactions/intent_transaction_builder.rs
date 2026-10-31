//! Translate an `IntentIR` into a `TransactionIR`.
//!
//! The verb table is the whole contract: an unrecognised verb is an error, never a
//! best-effort guess. Argument lookup is by the intent's own argument names, and a
//! whitespace-only string argument counts as **absent** (Swift trimmed before deciding),
//! so `name: "   "` raises `MissingArgument` rather than naming an entity "   ".

use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::planning::intent_ir::{IntentArgumentValue, IntentIR, IntentSource};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionBaseRevisions, TransactionIR, TransactionOperation,
    TransactionProvenance,
};

/// What the builder needs from the surrounding editor.
pub struct IntentTransactionBuildContext {
    pub scene_runtime: SceneRuntime,
    pub selected_entity_id: Option<u64>,
    pub default_spawn_mesh_index: i64,
}

impl IntentTransactionBuildContext {
    pub fn new(scene_runtime: SceneRuntime) -> Self {
        IntentTransactionBuildContext {
            scene_runtime,
            selected_entity_id: None,
            default_spawn_mesh_index: 0,
        }
    }
}

/// Why an intent could not be turned into a transaction.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum IntentTransactionBuilderError {
    #[error("unsupported intent verb: {0}")]
    UnsupportedVerb(String),
    #[error("intent {verb_id} is missing argument {argument}")]
    MissingArgument { verb_id: String, argument: String },
    #[error("intent {verb_id} has invalid argument {argument}")]
    InvalidArgument { verb_id: String, argument: String },
    #[error("intent {verb_id} requires a target entity")]
    MissingTarget { verb_id: String },
    #[error("invalid intent target: {0}")]
    InvalidTarget(String),
}

/// Builds transactions from intents.
pub struct IntentTransactionBuilder {
    _private: (),
}

impl IntentTransactionBuilder {
    pub fn new() -> Self {
        IntentTransactionBuilder { _private: () }
    }

    /// Translate `intent` into a transaction, or explain why it cannot be.
    pub fn build_transaction(
        &self,
        intent: &IntentIR,
        context: &IntentTransactionBuildContext,
    ) -> Result<TransactionIR, IntentTransactionBuilderError> {
        let mutations: Vec<SceneMutation>;
        let summary: String;

        match intent.verb.as_str() {
            "scene.spawn_entity" | "scene.create_instance" => {
                let label = self
                    .string_argument(intent, "label")
                    .unwrap_or_else(|| "AI Entity".to_string());
                let position = self
                    .vec3_argument(intent, "position")
                    .unwrap_or(Float3::ZERO);
                mutations = vec![SceneMutation::SpawnImportedMeshEntity {
                    label,
                    kind_label: "Static Mesh".to_string(),
                    mesh_index: context.default_spawn_mesh_index,
                    position,
                    parent_id: None,
                }];
                summary = non_empty_or(intent, "Spawn scene entity");
            }
            "scene.set_name" => {
                let entity_id = self.target_entity_id(intent, context)?;
                let Some(name) = self.string_argument(intent, "name") else {
                    return Err(IntentTransactionBuilderError::MissingArgument {
                        verb_id: intent.verb.clone(),
                        argument: "name".to_string(),
                    });
                };
                mutations = vec![SceneMutation::SetSceneName {
                    entity_id,
                    value: name,
                }];
                summary = non_empty_or(intent, "Rename selected entity");
            }
            "scene.duplicate_entity" => {
                let entity_id = self.target_entity_id(intent, context)?;
                mutations = vec![SceneMutation::DuplicateEntity { entity_id }];
                summary = non_empty_or(intent, "Duplicate selected entity");
            }
            "scene.delete_entity" | "scene.delete_instance" => {
                let entity_id = self.target_entity_id(intent, context)?;
                mutations = vec![SceneMutation::DeleteEntity { entity_id }];
                summary = non_empty_or(intent, "Delete selected entity");
            }
            "scene.set_transform" | "scene.set_local_transform" => {
                let entity_id = self.target_entity_id(intent, context)?;
                let Some(translation) = self
                    .vec3_argument(intent, "translation")
                    .or_else(|| self.vec3_argument(intent, "position"))
                else {
                    return Err(IntentTransactionBuilderError::MissingArgument {
                        verb_id: intent.verb.clone(),
                        argument: "translation".to_string(),
                    });
                };
                let entity = entity_id_from_raw(entity_id);
                if !context.scene_runtime.contains(entity) {
                    return Err(IntentTransactionBuilderError::InvalidTarget(format!(
                        "scene:{entity_id}"
                    )));
                }
                // Preserve the existing rotation and scale; only the translation moves.
                let mut transform = context
                    .scene_runtime
                    .local_transform(entity)
                    .unwrap_or(LocalTransform::IDENTITY);
                transform.matrix.set_column(
                    3,
                    Float4::new(translation.x, translation.y, translation.z, 1.0),
                );
                mutations = vec![SceneMutation::SetLocalTransform {
                    entity_id,
                    transform,
                }];
                summary = non_empty_or(intent, "Set selected transform");
            }
            "scene.snap_to_ground" => {
                let entity_id = self.target_entity_id(intent, context)?;
                let entity = entity_id_from_raw(entity_id);
                if !context.scene_runtime.contains(entity) {
                    return Err(IntentTransactionBuilderError::InvalidTarget(format!(
                        "scene:{entity_id}"
                    )));
                }
                let mut transform = context
                    .scene_runtime
                    .local_transform(entity)
                    .unwrap_or(LocalTransform::IDENTITY);
                transform.matrix.set_column(
                    3,
                    Float4::new(
                        transform.matrix.columns[3].x,
                        0.0,
                        transform.matrix.columns[3].z,
                        1.0,
                    ),
                );
                mutations = vec![SceneMutation::SetLocalTransform {
                    entity_id,
                    transform,
                }];
                summary = "Snap entity to ground".to_string();
            }
            "scene.set_camera_pose" => {
                let entity_id = self.target_entity_id(intent, context)?;
                let position = self
                    .vec3_argument(intent, "position")
                    .unwrap_or(Float3::ZERO);
                let target = self
                    .vec3_argument(intent, "target")
                    .unwrap_or(Float3::new(0.0, 0.0, -1.0));

                let mut transform = LocalTransform::IDENTITY;
                transform
                    .matrix
                    .set_column(3, Float4::new(position.x, position.y, position.z, 1.0));
                // `up` is passed as an explicit null in Swift, so it is not part of the
                // merged fields; only `target` is written.
                let fields = ComponentValue::Object(
                    [(
                        "target".to_string(),
                        ComponentValue::Array(vec![
                            ComponentValue::Number(f64::from(target.x)),
                            ComponentValue::Number(f64::from(target.y)),
                            ComponentValue::Number(f64::from(target.z)),
                        ]),
                    )]
                    .into_iter()
                    .collect(),
                );
                mutations = vec![
                    SceneMutation::SetLocalTransform {
                        entity_id,
                        transform,
                    },
                    SceneMutation::SetComponentData {
                        entity_id,
                        type_id: "camera".to_string(),
                        value: fields,
                        mode: diffuse_scene::components::editing::ComponentWriteMode::Merge,
                    },
                ];
                summary = "Set camera pose".to_string();
            }
            "scene.set_camera_aspect_ratio" => {
                let entity_id = self.target_entity_id(intent, context)?;
                let Some(aspect_ratio) = self.number_argument(intent, "aspect_ratio") else {
                    return Err(IntentTransactionBuilderError::MissingArgument {
                        verb_id: intent.verb.clone(),
                        argument: "aspect_ratio".to_string(),
                    });
                };
                let fields = ComponentValue::Object(
                    [(
                        "aspectRatio".to_string(),
                        ComponentValue::Number(f64::from(aspect_ratio)),
                    )]
                    .into_iter()
                    .collect(),
                );
                mutations = vec![SceneMutation::SetComponentData {
                    entity_id,
                    type_id: "camera".to_string(),
                    value: fields,
                    mode: diffuse_scene::components::editing::ComponentWriteMode::Merge,
                }];
                summary = non_empty_or(intent, "Set camera aspect ratio");
            }
            other => {
                return Err(IntentTransactionBuilderError::UnsupportedVerb(
                    other.to_string(),
                ));
            }
        }

        let mut transaction = TransactionIR::new(
            summary,
            mutations
                .into_iter()
                .map(TransactionOperation::Scene)
                .collect(),
            // An AI intent produces a proposal; everything else is authored by a human.
            if intent.source == IntentSource::Ai {
                TransactionProvenance::Proposal
            } else {
                TransactionProvenance::Authored
            },
        );
        transaction.intent = Some(intent.clone());
        transaction.base_revisions = TransactionBaseRevisions {
            scene_revision: Some(context.scene_runtime.snapshot().revision),
            sequence_revision_id: None,
            asset_revision_id: None,
        };
        Ok(transaction)
    }

    /// The entity the intent acts on, in priority order: explicit argument, first
    /// target object id, then the editor's selection.
    fn target_entity_id(
        &self,
        intent: &IntentIR,
        context: &IntentTransactionBuildContext,
    ) -> Result<u64, IntentTransactionBuilderError> {
        if let Some(raw) = self.stable_id_argument(intent, "entity_id") {
            return Ok(raw);
        }
        if let Some(target) = intent.target_object_ids.first() {
            return Self::raw_entity_id(target);
        }
        if let Some(selected) = context.selected_entity_id {
            return Ok(selected);
        }
        Err(IntentTransactionBuilderError::MissingTarget {
            verb_id: intent.verb.clone(),
        })
    }

    fn string_argument(&self, intent: &IntentIR, name: &str) -> Option<String> {
        let IntentArgumentValue::String(value) = intent.arguments.get(name)? else {
            return None;
        };
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    fn stable_id_argument(&self, intent: &IntentIR, name: &str) -> Option<u64> {
        match intent.arguments.get(name) {
            Some(IntentArgumentValue::StableId(value)) => Some(*value),
            Some(IntentArgumentValue::Integer(value)) if *value >= 0 => Some(*value as u64),
            _ => None,
        }
    }

    fn vec3_argument(&self, intent: &IntentIR, name: &str) -> Option<Float3> {
        match intent.arguments.get(name)? {
            IntentArgumentValue::Vec3(value) => Some(value.simd_value()),
            _ => None,
        }
    }

    fn number_argument(&self, intent: &IntentIR, name: &str) -> Option<f32> {
        match intent.arguments.get(name)? {
            IntentArgumentValue::Number(value) => Some(*value as f32),
            IntentArgumentValue::Integer(value) => Some(*value as f32),
            _ => None,
        }
    }

    /// Accept both `scene:123` and a bare `123`.
    fn raw_entity_id(target: &str) -> Result<u64, IntentTransactionBuilderError> {
        let raw = target.strip_prefix("scene:").unwrap_or(target);
        raw.parse::<u64>()
            .map_err(|_| IntentTransactionBuilderError::InvalidTarget(target.to_string()))
    }
}

impl Default for IntentTransactionBuilder {
    fn default() -> Self {
        Self::new()
    }
}

fn non_empty_or(intent: &IntentIR, fallback: &str) -> String {
    if intent.summary.is_empty() {
        fallback.to_string()
    } else {
        intent.summary.clone()
    }
}

/// Rebuild an `EntityID` from the packed `u64` form (low 32 bits index, high 32 bits
/// generation).
pub fn entity_id_from_raw(raw_id: u64) -> diffuse_scene::entity_id::EntityID {
    diffuse_scene::entity_id::EntityID::new((raw_id & 0xFFFF_FFFF) as u32, (raw_id >> 32) as u32)
}

/// Pack an `EntityID` back into the `u64` form used by documents and intents.
pub fn raw_entity_id_of(entity: diffuse_scene::entity_id::EntityID) -> u64 {
    entity.raw_value()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planning::intent_ir::IntentVector3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::scene_bootstrap::SceneNameComponent;

    fn context_with_entity() -> (IntentTransactionBuildContext, u64) {
        let mut runtime = SceneRuntime::new(ComponentRegistry::new());
        let entity = runtime.create_entity();
        runtime.set_component(SceneNameComponent::new("hero"), entity);
        let raw = raw_entity_id_of(entity);
        (IntentTransactionBuildContext::new(runtime), raw)
    }

    fn intent(verb: &str) -> IntentIR {
        IntentIR::new(verb, "a summary", IntentSource::Ai)
    }

    #[test]
    fn an_unknown_verb_is_rejected() {
        let (context, _) = context_with_entity();
        let error = IntentTransactionBuilder::new()
            .build_transaction(&intent("scene.teleport"), &context)
            .expect_err("must reject");
        assert_eq!(
            error,
            IntentTransactionBuilderError::UnsupportedVerb("scene.teleport".to_string())
        );
    }

    #[test]
    fn an_ai_intent_becomes_a_proposal() {
        let (context, _) = context_with_entity();
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&intent("scene.spawn_entity"), &context)
            .expect("build");
        assert_eq!(transaction.provenance, TransactionProvenance::Proposal);
        assert_eq!(transaction.operations.len(), 1);
    }

    #[test]
    fn a_human_intent_is_authored() {
        let (context, _) = context_with_entity();
        let mut human = IntentIR::new("scene.spawn_entity", "", IntentSource::Human);
        human.summary = "spawn".to_string();
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&human, &context)
            .expect("build");
        assert_eq!(transaction.provenance, TransactionProvenance::Authored);
    }

    #[test]
    fn a_whitespace_only_name_counts_as_missing() {
        let (context, raw) = context_with_entity();
        let mut request = intent("scene.set_name");
        request
            .arguments
            .insert("entity_id".to_string(), IntentArgumentValue::StableId(raw));
        request.arguments.insert(
            "name".to_string(),
            IntentArgumentValue::String("   ".to_string()),
        );
        let error = IntentTransactionBuilder::new()
            .build_transaction(&request, &context)
            .expect_err("must reject");
        assert_eq!(
            error,
            IntentTransactionBuilderError::MissingArgument {
                verb_id: "scene.set_name".to_string(),
                argument: "name".to_string(),
            }
        );
    }

    #[test]
    fn a_target_object_id_is_accepted_with_or_without_the_scene_prefix() {
        let (context, raw) = context_with_entity();
        let mut request = intent("scene.delete_entity");
        request.target_object_ids.push(format!("scene:{raw}"));
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&request, &context)
            .expect("build");
        match &transaction.operations[0] {
            TransactionOperation::Scene(SceneMutation::DeleteEntity { entity_id }) => {
                assert_eq!(*entity_id, raw);
            }
            other => panic!("expected a delete, got {other:?}"),
        }
    }

    #[test]
    fn the_editor_selection_is_the_last_resort_target() {
        let (mut context, raw) = context_with_entity();
        context.selected_entity_id = Some(raw);
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&intent("scene.duplicate_entity"), &context)
            .expect("build");
        assert_eq!(transaction.operations.len(), 1);
    }

    #[test]
    fn a_missing_target_is_reported_when_there_is_no_selection() {
        let (context, _) = context_with_entity();
        let error = IntentTransactionBuilder::new()
            .build_transaction(&intent("scene.delete_entity"), &context)
            .expect_err("must reject");
        assert_eq!(
            error,
            IntentTransactionBuilderError::MissingTarget {
                verb_id: "scene.delete_entity".to_string()
            }
        );
    }

    #[test]
    fn an_unknown_entity_target_is_rejected_for_a_transform() {
        let (context, _) = context_with_entity();
        let mut request = intent("scene.set_transform");
        request.arguments.insert(
            "entity_id".to_string(),
            IntentArgumentValue::StableId(999_999),
        );
        request.arguments.insert(
            "translation".to_string(),
            IntentArgumentValue::Vec3(IntentVector3::new(1.0, 2.0, 3.0)),
        );
        let error = IntentTransactionBuilder::new()
            .build_transaction(&request, &context)
            .expect_err("must reject");
        assert!(matches!(
            error,
            IntentTransactionBuilderError::InvalidTarget(_)
        ));
    }

    #[test]
    fn setting_a_transform_preserves_rotation_and_scale() {
        let (context, raw) = context_with_entity();
        let mut request = intent("scene.set_transform");
        request
            .arguments
            .insert("entity_id".to_string(), IntentArgumentValue::StableId(raw));
        request.arguments.insert(
            "translation".to_string(),
            IntentArgumentValue::Vec3(IntentVector3::new(4.0, 5.0, 6.0)),
        );
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&request, &context)
            .expect("build");
        let TransactionOperation::Scene(SceneMutation::SetLocalTransform { transform, .. }) =
            &transaction.operations[0]
        else {
            panic!("expected a transform");
        };
        assert_eq!(transform.matrix.columns[3].x, 4.0);
        assert_eq!(transform.matrix.columns[3].y, 5.0);
        assert_eq!(transform.matrix.columns[3].z, 6.0);
        // The basis is untouched: identity rotation and unit scale survive.
        assert_eq!(transform.matrix.columns[0].x, 1.0);
    }

    #[test]
    fn snapping_to_ground_zeroes_only_y() {
        let (context, raw) = context_with_entity();
        let mut request = intent("scene.snap_to_ground");
        request
            .arguments
            .insert("entity_id".to_string(), IntentArgumentValue::StableId(raw));
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&request, &context)
            .expect("build");
        let TransactionOperation::Scene(SceneMutation::SetLocalTransform { transform, .. }) =
            &transaction.operations[0]
        else {
            panic!("expected a transform");
        };
        assert_eq!(transform.matrix.columns[3].y, 0.0);
        assert_eq!(transform.matrix.columns[3].w, 1.0);
    }

    #[test]
    fn the_base_revision_is_recorded() {
        let (context, _) = context_with_entity();
        let revision = context.scene_runtime.snapshot().revision;
        let transaction = IntentTransactionBuilder::new()
            .build_transaction(&intent("scene.spawn_entity"), &context)
            .expect("build");
        assert_eq!(transaction.base_revisions.scene_revision, Some(revision));
    }
}
