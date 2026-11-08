//! Converts a legacy `SceneEditPlan` into an executable `TransactionIR`.
//!
//! Each `SceneEditStep` is authorised through its capability contract, validated
//! against the strict input schema, and expanded by its typed prepare. The
//! resulting transaction has no `IntentIR`, explicit capability invocation
//! records, and `proposal` provenance.

use std::collections::BTreeMap;
use std::fmt;

use diffuse_capability::capability_contract::CapabilityExposureSnapshot;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::validate_capability_input;
use diffuse_intent::transactions::transaction_ir::{
    CapabilityInvocationRecord, SceneMutation, TransactionApprovalPolicy, TransactionIR,
    TransactionOperation, TransactionProvenance, TransactionVerificationAssertion,
};
use diffuse_intent::{
    BuiltInTypedCapabilityCatalog, CapabilityPreparationContext, CapabilityPreparationEntity,
    CapabilityPreparationMaterial, CapabilityPreparationTransform, TransactionExecutionContext,
    TransactionExecutor,
};
use diffuse_kernel::codable::new_uuid;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, Quatf, simd_length};
use diffuse_observation::event_envelope::EventOrigin;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::media::audio::AudioSource;
use diffuse_scene::physics::collider::{Collider, ColliderShape, ColliderShapeKind};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType};
use diffuse_scene::rendering::render_extraction::{
    LightComponent, LightType, RenderMaterialComponent,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use diffuse_script::interop::component_registry_script_codec::encode_script_binding_for_editing;
use serde_json::value::RawValue;

use crate::planning::scene_edit_plan::{JSONValue, SceneEditOp, SceneEditPlan, SceneEditStep};

#[derive(Clone, Debug, PartialEq)]
pub enum SceneEditPlanExecutorError {
    InvalidEntityRef(String),
    MissingEntityRef {
        op: SceneEditOp,
    },
    EntityNotFound(String),
    MissingField {
        op: SceneEditOp,
        field: String,
    },
    InvalidColor {
        op: SceneEditOp,
    },
    UnknownLightType(String),
    UnknownMotionType(String),
    UnknownColliderShape(String),
    CapabilityUnavailable(String),
    InvalidCapabilityInput {
        capability_id: String,
        reason: String,
    },
}

impl fmt::Display for SceneEditPlanExecutorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SceneEditPlanExecutorError::InvalidEntityRef(reference) => write!(
                formatter,
                "invalid entity reference: '{reference}' — expected format 'scene:<uint64>'"
            ),
            SceneEditPlanExecutorError::MissingEntityRef { op } => {
                write!(formatter, "op '{}' requires entity_id", op.raw_value())
            }
            SceneEditPlanExecutorError::EntityNotFound(reference) => {
                write!(formatter, "entity '{reference}' not found in scene")
            }
            SceneEditPlanExecutorError::MissingField { op, field } => {
                write!(
                    formatter,
                    "op '{}' requires field '{field}'",
                    op.raw_value()
                )
            }
            SceneEditPlanExecutorError::InvalidColor { op } => write!(
                formatter,
                "op '{}' color must be [r, g, b] with 3 elements",
                op.raw_value()
            ),
            SceneEditPlanExecutorError::UnknownLightType(value) => write!(
                formatter,
                "unknown light type '{value}' — expected 'directional', 'point', or 'spot'"
            ),
            SceneEditPlanExecutorError::UnknownMotionType(value) => write!(
                formatter,
                "unknown motion type '{value}' — expected 'static', 'dynamic', or 'kinematic'"
            ),
            SceneEditPlanExecutorError::UnknownColliderShape(value) => write!(
                formatter,
                "unknown collider shape '{value}' — expected 'box', 'sphere', 'capsule', 'cylinder', 'heightField', 'mesh', or 'convex'"
            ),
            SceneEditPlanExecutorError::CapabilityUnavailable(capability_id) => write!(
                formatter,
                "capability '{capability_id}' is not registered for AI exposure"
            ),
            SceneEditPlanExecutorError::InvalidCapabilityInput {
                capability_id,
                reason,
            } => write!(
                formatter,
                "invalid input for capability '{capability_id}': {reason}"
            ),
        }
    }
}

impl std::error::Error for SceneEditPlanExecutorError {}

/// Turns a decoded AI plan into an executable `TransactionIR`.
#[derive(Clone, Copy, Debug, Default)]
pub struct SceneEditPlanExecutor;

struct CanonicalCapabilityInput {
    data: String,
    argument_names: Vec<String>,
}

impl SceneEditPlanExecutor {
    pub fn new() -> Self {
        Self
    }

    /// Builds a transaction with no base revision, automatic approval, and the
    /// built-in AI-exposed capability registry.
    pub fn build_transaction_with_defaults(
        &self,
        plan: &SceneEditPlan,
        scene: &SceneRuntime,
    ) -> Result<TransactionIR, SceneEditPlanExecutorError> {
        self.build_transaction(
            plan,
            scene,
            None,
            TransactionApprovalPolicy::Automatic,
            None,
            &BuiltInTypedCapabilityCatalog::registry(),
        )
    }

    /// Builds a `TransactionIR` from the plan.
    ///
    /// `base_scene_revision` is the revision the AI generated the plan at;
    /// passing the snapshot's revision prevents applying a plan against a scene
    /// that changed while the API call was in flight.
    pub fn build_transaction(
        &self,
        plan: &SceneEditPlan,
        scene: &SceneRuntime,
        base_scene_revision: Option<u64>,
        approval_policy: TransactionApprovalPolicy,
        exposure_snapshot: Option<&CapabilityExposureSnapshot>,
        registry: &CapabilityRegistry,
    ) -> Result<TransactionIR, SceneEditPlanExecutorError> {
        let mut mutations: Vec<SceneMutation> = Vec::new();
        let mut invocations: Vec<CapabilityInvocationRecord> = Vec::new();
        let mut assertions: Vec<TransactionVerificationAssertion> = Vec::new();
        let snapshot_id = exposure_snapshot
            .map(|snapshot| snapshot.id.clone())
            .unwrap_or_else(new_uuid);
        // Shadow copy — each step reads the post-previous-step state so multi-step
        // plans that touch the same component don't silently overwrite each
        // other's changes.
        let mut local_scene = scene.clone();
        for step in &plan.steps {
            let capability_id = step.op.capability_id();
            let descriptor = registry
                .descriptor(capability_id)
                .filter(|descriptor| descriptor.is_ai_exposed)
                .ok_or_else(|| {
                    SceneEditPlanExecutorError::CapabilityUnavailable(capability_id.to_string())
                })?;
            let descriptor_contract = descriptor.contract();
            let contract = match exposure_snapshot {
                Some(snapshot) => snapshot
                    .contract(capability_id)
                    .filter(|exposed| {
                        exposed.version == descriptor.version
                            && exposed.schema_hash == descriptor_contract.schema_hash
                    })
                    .cloned()
                    .ok_or_else(|| {
                        SceneEditPlanExecutorError::CapabilityUnavailable(capability_id.to_string())
                    })?,
                None => descriptor_contract,
            };
            // `SceneEditPlan` is the compatibility transport while callers move
            // to direct capability drafts. Preserve its established diagnostic
            // errors, but discard the legacy mutations: authority and actual
            // operations come from strict validation and typed prepare.
            if let Some(error) = legacy_validation_error(step, &local_scene) {
                return Err(error);
            }
            let input = canonical_capability_input(step)?;
            let value: serde_json::Value = serde_json::from_str(&input.data)
                .map_err(|error| invalid_capability_input(&contract.id, error.to_string()))?;
            validate_capability_input(&value, &contract.input_schema)
                .map_err(|error| invalid_capability_input(&contract.id, error.to_string()))?;
            let registration = BuiltInTypedCapabilityCatalog::registration(&contract.id)
                .filter(|registration| registration.contract.schema_hash == contract.schema_hash)
                .ok_or_else(|| {
                    // AI writes never fall back to legacy mutation lowering. A
                    // catalog omission is an unavailable capability.
                    SceneEditPlanExecutorError::CapabilityUnavailable(contract.id.clone())
                })?;
            let prepared = registration
                .prepare(input.data.as_bytes(), &preparation_context(&local_scene))
                .map_err(|error| invalid_capability_input(&contract.id, error.to_string()))?;
            let mut step_mutations: Vec<SceneMutation> = Vec::new();
            for operation in prepared.operations {
                match operation {
                    TransactionOperation::Scene(mutation) => step_mutations.push(mutation),
                    _ => {
                        return Err(invalid_capability_input(
                            &contract.id,
                            "a scene capability prepared a non-scene operation".to_string(),
                        ));
                    }
                }
            }
            let step_assertions = prepared.assertions;
            mutations.extend(step_mutations.iter().cloned());
            assertions.extend(step_assertions);
            let mut invocation = CapabilityInvocationRecord::new(
                contract.id.clone(),
                contract.version,
                contract.schema_hash.clone(),
                contract.input_digest(input.data.as_bytes()),
                contract.access,
            )
            .with_argument_names(input.argument_names);
            invocation.source_plugin_id = contract.source.plugin_id.clone();
            invocation.plugin_authority =
                contract.source.plugin_id.as_ref().and_then(|plugin_id| {
                    exposure_snapshot.and_then(|snapshot| snapshot.authority(plugin_id).cloned())
                });
            invocation.target_references = step.entity_ref.iter().cloned().collect();
            invocation.exposure_snapshot_id = snapshot_id.clone();
            invocations.push(invocation);
            apply_to_local_scene(&mut local_scene, &step_mutations);
        }
        let expected_created_count = mutations
            .iter()
            .filter(|mutation| {
                matches!(
                    mutation,
                    SceneMutation::SpawnImportedMeshEntity { .. }
                        | SceneMutation::SpawnEmptyEntity { .. }
                        | SceneMutation::SpawnLightEntity { .. }
                        | SceneMutation::SpawnCameraEntity { .. }
                        | SceneMutation::DuplicateEntity { .. }
                        | SceneMutation::DuplicateEntityWithOffset { .. }
                )
            })
            .count();
        if expected_created_count > 0 {
            assertions.push(TransactionVerificationAssertion::CreatedEntityCount(
                expected_created_count,
            ));
        }
        if let Some(from) = base_scene_revision {
            assertions.push(TransactionVerificationAssertion::SceneRevisionAdvanced { from });
        }
        let mut transaction = TransactionIR::new(
            plan.summary.clone(),
            mutations
                .into_iter()
                .map(TransactionOperation::Scene)
                .collect(),
            TransactionProvenance::Proposal,
        );
        transaction.capability_invocations = invocations;
        transaction.verification_assertions = assertions;
        transaction.base_revisions.scene_revision = base_scene_revision;
        transaction.approval_policy = approval_policy;
        Ok(transaction)
    }
}

fn preparation_context(scene: &SceneRuntime) -> CapabilityPreparationContext {
    let entities = scene
        .entities()
        .into_iter()
        .map(|entity| {
            let transform = scene.local_transform(entity).and_then(|local| {
                let matrix = local.matrix;
                CapabilityPreparationTransform::new(vec![
                    matrix.columns[0].x,
                    matrix.columns[0].y,
                    matrix.columns[0].z,
                    matrix.columns[0].w,
                    matrix.columns[1].x,
                    matrix.columns[1].y,
                    matrix.columns[1].z,
                    matrix.columns[1].w,
                    matrix.columns[2].x,
                    matrix.columns[2].y,
                    matrix.columns[2].z,
                    matrix.columns[2].w,
                    matrix.columns[3].x,
                    matrix.columns[3].y,
                    matrix.columns[3].z,
                    matrix.columns[3].w,
                ])
            });
            let mut component_types: Vec<String> = scene
                .component_registry()
                .schemas
                .iter()
                .filter(|schema| scene.has_component_by_type_id(&schema.type_id, entity))
                .map(|schema| {
                    schema
                        .runtime_type_name
                        .rsplit("::")
                        .next()
                        .unwrap_or_default()
                        .to_string()
                })
                .collect();
            // Bare entities expose an implicit identity transform to capabilities.
            if transform.is_some() && !component_types.iter().any(|name| name == "LocalTransform") {
                component_types.push("LocalTransform".to_string());
            }
            let render_material =
                scene
                    .component::<RenderMaterialComponent>(entity)
                    .and_then(|material| {
                        CapabilityPreparationMaterial::new(
                            vec![
                                material.base_color_factor.x,
                                material.base_color_factor.y,
                                material.base_color_factor.z,
                                material.base_color_factor.w,
                            ],
                            material.base_color_texture_index,
                            material.normal_texture_index,
                            material.metallic_factor,
                            material.roughness_factor,
                            vec![
                                material.emissive_factor.x,
                                material.emissive_factor.y,
                                material.emissive_factor.z,
                            ],
                        )
                    });
            CapabilityPreparationEntity::new(
                format!("scene:{}", entity.raw_value()),
                component_types,
                transform,
                render_material,
                scene.component::<RigidBody>(entity),
                scene.component::<Collider>(entity),
                scene.component::<LightComponent>(entity),
                scene.component::<AudioSource>(entity),
                scene.component::<AnimationPlayer>(entity),
                scene
                    .component::<ScriptComponent>(entity)
                    .map(|component| component.bindings)
                    .unwrap_or_default(),
            )
        })
        .collect();
    CapabilityPreparationContext::new(scene.snapshot().revision, entities)
}

fn legacy_validation_error(
    step: &SceneEditStep,
    scene: &SceneRuntime,
) -> Option<SceneEditPlanExecutorError> {
    build_mutations(step, scene).err()
}

fn canonical_capability_input(
    step: &SceneEditStep,
) -> Result<CanonicalCapabilityInput, SceneEditPlanExecutorError> {
    let encoded = serde_json::to_string(step)
        .map_err(|error| invalid_capability_input(step.op.capability_id(), error.to_string()))?;
    let mut object: BTreeMap<String, Box<RawValue>> =
        serde_json::from_str(&encoded).map_err(|_| {
            invalid_capability_input(
                step.op.capability_id(),
                "input is not a JSON object".to_string(),
            )
        })?;
    object.remove("op");
    let data = serde_json::to_string(&object)
        .map_err(|error| invalid_capability_input(step.op.capability_id(), error.to_string()))?;
    let argument_names = object.keys().cloned().collect();
    Ok(CanonicalCapabilityInput {
        data,
        argument_names,
    })
}

/// Applies the component-level side-effects of `mutations` to `scene` so that
/// subsequent steps in the same plan see the accumulated state.
fn apply_to_local_scene(scene: &mut SceneRuntime, mutations: &[SceneMutation]) {
    let mut context = TransactionExecutionContext::new(
        Some(scene.clone()),
        None,
        None,
        None,
        EventOrigin::tool(None, None),
        "scene:main",
        "transaction",
        "asset:project",
        "ui:confirmation",
    );
    let transaction = TransactionIR::new(
        "Prepare scene edits",
        mutations
            .iter()
            .cloned()
            .map(TransactionOperation::Scene)
            .collect(),
        TransactionProvenance::Authored,
    );
    if TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .is_ok()
        && let Some(updated) = context.scene_runtime
    {
        *scene = updated;
    }
}

fn build_mutations(
    step: &SceneEditStep,
    scene: &SceneRuntime,
) -> Result<Vec<SceneMutation>, SceneEditPlanExecutorError> {
    match step.op {
        SceneEditOp::SpawnEntity => {
            let label = step
                .label
                .clone()
                .unwrap_or_else(|| "AI Entity".to_string());
            let position = simd3(step.spawn_position.as_deref()).unwrap_or(Float3::ZERO);
            let parent_id = resolve_optional_ref(step.spawn_parent_ref.as_deref(), scene)?;
            Ok(match step.spawn_kind.as_deref().unwrap_or("mesh") {
                "empty" => vec![SceneMutation::SpawnEmptyEntity {
                    label,
                    position,
                    parent_id,
                }],
                "light" => {
                    let light_type = step
                        .light_type
                        .as_deref()
                        .and_then(LightType::from_raw_value)
                        .unwrap_or(LightType::Point);
                    let color = step
                        .color
                        .as_deref()
                        .filter(|color| color.len() >= 3)
                        .map(|color| Float3::new(color[0], color[1], color[2]));
                    vec![SceneMutation::SpawnLightEntity {
                        label,
                        light_type,
                        position,
                        initial_intensity: step.intensity,
                        initial_color: color,
                        initial_range: step.range,
                        initial_cast_shadows: step.light_cast_shadows,
                        parent_id,
                    }]
                }
                "camera" => vec![SceneMutation::SpawnCameraEntity {
                    label,
                    position,
                    initial_fov_y_degrees: step.camera_fov_y_degrees,
                    parent_id,
                }],
                _ => vec![SceneMutation::SpawnImportedMeshEntity {
                    label,
                    kind_label: "Static Mesh".to_string(),
                    mesh_index: 0,
                    position,
                    parent_id,
                }],
            })
        }

        SceneEditOp::DeleteEntity => {
            let entity_id = resolve_entity_id(step, scene)?;
            Ok(vec![SceneMutation::DeleteEntity { entity_id }])
        }

        SceneEditOp::DuplicateEntity => {
            let entity_id = resolve_entity_id(step, scene)?;
            if let Some(offset) = step
                .duplicate_offset
                .as_deref()
                .filter(|offset| offset.len() >= 3)
            {
                return Ok(vec![SceneMutation::DuplicateEntityWithOffset {
                    entity_id,
                    position_offset: Float3::new(offset[0], offset[1], offset[2]),
                }]);
            }
            Ok(vec![SceneMutation::DuplicateEntity { entity_id }])
        }

        SceneEditOp::ReparentEntity => {
            let entity_id = resolve_entity_id(step, scene)?;
            let parent_id = resolve_optional_ref(step.parent_ref.as_deref(), scene)?;
            Ok(vec![SceneMutation::MoveEntity {
                entity_id,
                parent_id,
                index: i64::MAX,
            }])
        }

        SceneEditOp::SetName => {
            let entity_id = resolve_entity_id(step, scene)?;
            let name = step
                .name
                .clone()
                .filter(|name| !name.is_empty())
                .ok_or_else(|| missing_field(step.op, "name"))?;
            Ok(vec![SceneMutation::SetSceneName {
                entity_id,
                value: name,
            }])
        }

        SceneEditOp::SetTransform => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let mut transform = scene
                .local_transform(entity)
                .unwrap_or(LocalTransform::IDENTITY);
            if let Some(position) = simd3(step.position.as_deref()) {
                transform.matrix.columns[3] = Float4::new(position.x, position.y, position.z, 1.0);
            }
            if let Some(euler) = step
                .euler_degrees
                .as_deref()
                .filter(|euler| euler.len() >= 3)
            {
                let rotation = rotation_matrix(Float3::new(euler[0], euler[1], euler[2]));
                let scale = extract_scale(&transform.matrix);
                transform.matrix = compose_matrix(transform.translation(), rotation, scale);
            }
            if let Some(scale) = simd3(step.scale.as_deref()) {
                let rotation = rotation_only(&transform.matrix);
                transform.matrix = compose_matrix(transform.translation(), rotation, scale);
            }
            Ok(vec![SceneMutation::SetLocalTransform {
                entity_id,
                transform,
            }])
        }

        SceneEditOp::SnapToGround => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let mut transform = scene
                .local_transform(entity)
                .unwrap_or(LocalTransform::IDENTITY);
            transform.matrix.columns[3].y = 0.0;
            Ok(vec![SceneMutation::SetLocalTransform {
                entity_id,
                transform,
            }])
        }

        SceneEditOp::SetLightType => {
            let entity_id = resolve_entity_id(step, scene)?;
            let type_name = step
                .light_type
                .as_deref()
                .ok_or_else(|| missing_field(step.op, "light_type"))?;
            let light_type = LightType::from_raw_value(type_name).ok_or_else(|| {
                SceneEditPlanExecutorError::UnknownLightType(type_name.to_string())
            })?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "light",
                [(
                    "type".to_string(),
                    Some(ComponentValue::String(light_type.raw_value().to_string())),
                )],
            )])
        }

        SceneEditOp::SetLightIntensity => {
            let entity_id = resolve_entity_id(step, scene)?;
            let intensity = step
                .intensity
                .ok_or_else(|| missing_field(step.op, "intensity"))?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "light",
                [("intensity".to_string(), Some(component_number(intensity)))],
            )])
        }

        SceneEditOp::SetMeshColor => {
            let entity_id = resolve_entity_id(step, scene)?;
            let color = step
                .color
                .as_deref()
                .filter(|color| color.len() == 3)
                .ok_or(SceneEditPlanExecutorError::InvalidColor { op: step.op })?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "renderMesh",
                [(
                    "colorTint".to_string(),
                    Some(component_vector(Float3::new(color[0], color[1], color[2]))),
                )],
            )])
        }

        SceneEditOp::SetMaterial => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let mut material = scene
                .component::<RenderMaterialComponent>(entity)
                .unwrap_or_else(default_render_material);
            if let Some(base_color) = step.material_base_color.as_deref() {
                if base_color.len() >= 4 {
                    material.base_color_factor =
                        Float4::new(base_color[0], base_color[1], base_color[2], base_color[3]);
                } else if base_color.len() >= 3 {
                    material.base_color_factor = Float4::new(
                        base_color[0],
                        base_color[1],
                        base_color[2],
                        material.base_color_factor.w,
                    );
                }
            }
            if let Some(metallic) = step.material_metallic {
                material.metallic_factor = metallic;
            }
            if let Some(roughness) = step.material_roughness {
                material.roughness_factor = roughness;
            }
            if let Some(emissive) = step
                .material_emissive
                .as_deref()
                .filter(|emissive| emissive.len() >= 3)
            {
                material.emissive_factor = Float3::new(emissive[0], emissive[1], emissive[2]);
            }
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "renderMaterial",
                [
                    (
                        "baseColorFactor".to_string(),
                        Some(component_vector4(material.base_color_factor)),
                    ),
                    (
                        "baseColorTextureIndex".to_string(),
                        Some(texture_index_value(material.base_color_texture_index)),
                    ),
                    (
                        "normalTextureIndex".to_string(),
                        Some(texture_index_value(material.normal_texture_index)),
                    ),
                    (
                        "metallicFactor".to_string(),
                        Some(component_number(material.metallic_factor)),
                    ),
                    (
                        "roughnessFactor".to_string(),
                        Some(component_number(material.roughness_factor)),
                    ),
                    (
                        "emissiveFactor".to_string(),
                        Some(component_vector(material.emissive_factor)),
                    ),
                ],
            )])
        }

        SceneEditOp::SetLightColor => {
            let entity_id = resolve_entity_id(step, scene)?;
            let color = step
                .color
                .as_deref()
                .filter(|color| color.len() == 3)
                .ok_or(SceneEditPlanExecutorError::InvalidColor { op: step.op })?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "light",
                [(
                    "color".to_string(),
                    Some(component_vector(Float3::new(color[0], color[1], color[2]))),
                )],
            )])
        }

        SceneEditOp::SetLightRange => {
            let entity_id = resolve_entity_id(step, scene)?;
            let range = step.range.ok_or_else(|| missing_field(step.op, "range"))?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "light",
                [("range".to_string(), Some(component_number(range)))],
            )])
        }

        SceneEditOp::SetLightSpotAngles => {
            let entity_id = resolve_entity_id(step, scene)?;
            let mut result = Vec::new();
            if let Some(inner) = step.spot_inner_angle_degrees {
                result.push(SceneMutation::component_fields(
                    entity_id,
                    "light",
                    [(
                        "spotInnerAngleDegrees".to_string(),
                        Some(component_number(inner)),
                    )],
                ));
            }
            if let Some(outer) = step.spot_outer_angle_degrees {
                result.push(SceneMutation::component_fields(
                    entity_id,
                    "light",
                    [(
                        "spotOuterAngleDegrees".to_string(),
                        Some(component_number(outer)),
                    )],
                ));
            }
            if result.is_empty() {
                return Err(missing_field(
                    step.op,
                    "spot_inner_angle or spot_outer_angle",
                ));
            }
            Ok(result)
        }

        SceneEditOp::SetLightCastShadows => {
            let entity_id = resolve_entity_id(step, scene)?;
            let cast_shadows = step.light_cast_shadows.unwrap_or(false);
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "light",
                [(
                    "castShadows".to_string(),
                    Some(ComponentValue::Bool(cast_shadows)),
                )],
            )])
        }

        SceneEditOp::SetCameraPose => {
            let entity_id = resolve_entity_id(step, scene)?;
            let position = simd3(step.position.as_deref()).unwrap_or(Float3::ZERO);
            let target =
                simd3(step.camera_target.as_deref()).unwrap_or(Float3::new(0.0, 0.0, -1.0));
            let up = simd3(step.camera_up.as_deref()).unwrap_or(Float3::new(0.0, 1.0, 0.0));
            let transform = LocalTransform::from_translation(position);
            Ok(vec![
                SceneMutation::SetLocalTransform {
                    entity_id,
                    transform,
                },
                SceneMutation::component_fields(
                    entity_id,
                    "camera",
                    [
                        ("target".to_string(), Some(component_vector(target))),
                        ("up".to_string(), Some(component_vector(up))),
                    ],
                ),
            ])
        }

        SceneEditOp::SetCameraFov => {
            let entity_id = resolve_entity_id(step, scene)?;
            let fov = step
                .camera_fov_y_degrees
                .ok_or_else(|| missing_field(step.op, "camera_fov_y"))?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "camera",
                [(
                    "fovYRadians".to_string(),
                    Some(component_number(fov * std::f32::consts::PI / 180.0)),
                )],
            )])
        }

        SceneEditOp::SetCameraAspectRatio => {
            let entity_id = resolve_entity_id(step, scene)?;
            let aspect_ratio = step
                .camera_aspect_ratio
                .ok_or_else(|| missing_field(step.op, "camera_aspect_ratio"))?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "camera",
                [(
                    "aspectRatio".to_string(),
                    Some(component_number(aspect_ratio)),
                )],
            )])
        }

        SceneEditOp::SetCameraActive => {
            let entity_id = resolve_entity_id(step, scene)?;
            let is_active = step.camera_is_active.unwrap_or(true);
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "camera",
                [(
                    "isActive".to_string(),
                    Some(ComponentValue::Bool(is_active)),
                )],
            )])
        }

        SceneEditOp::SetRigidBodyMotion => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let type_name = step
                .motion_type
                .as_deref()
                .ok_or_else(|| missing_field(step.op, "motion_type"))?;
            let motion_type = RigidBodyMotionType::from_raw_value(type_name).ok_or_else(|| {
                SceneEditPlanExecutorError::UnknownMotionType(type_name.to_string())
            })?;
            let mut body = scene.component::<RigidBody>(entity).unwrap_or_default();
            body.motion_type = motion_type;
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "rigidbody",
                body,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetRigidBodyMass => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let mass = step.mass.ok_or_else(|| missing_field(step.op, "mass"))?;
            let mut body = scene.component::<RigidBody>(entity).unwrap_or_default();
            body.mass = mass;
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "rigidbody",
                body,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetRigidBodyGravity => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let gravity_scale = step
                .gravity_scale
                .ok_or_else(|| missing_field(step.op, "gravity_scale"))?;
            let mut body = scene.component::<RigidBody>(entity).unwrap_or_default();
            body.gravity_scale = gravity_scale;
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "rigidbody",
                body,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetRigidBodyAllowSleep => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let allow_sleep = step
                .allow_sleep
                .ok_or_else(|| missing_field(step.op, "allow_sleep"))?;
            let mut body = scene.component::<RigidBody>(entity).unwrap_or_default();
            body.allow_sleep = allow_sleep;
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "rigidbody",
                body,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetColliderTrigger => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let is_trigger = step
                .is_trigger
                .ok_or_else(|| missing_field(step.op, "is_trigger"))?;
            let mut collider = scene
                .component::<Collider>(entity)
                .unwrap_or_else(default_collider);
            collider.is_trigger = is_trigger;
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetColliderLayer => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            if step.collider_layer_id.is_none() && step.collider_layer_mask.is_none() {
                return Err(missing_field(
                    step.op,
                    "collider_layer_id or collider_layer_mask",
                ));
            }
            let mut collider = scene
                .component::<Collider>(entity)
                .unwrap_or_else(default_collider);
            if let Some(layer_id) = step.collider_layer_id {
                collider.layer_id = clamp_u16(layer_id);
            }
            if let Some(layer_mask) = step.collider_layer_mask {
                collider.layer_mask = clamp_u16(layer_mask);
            }
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetConstraintEnabled => {
            let entity_id = resolve_entity_id(step, scene)?;
            let is_enabled = step
                .is_enabled
                .ok_or_else(|| missing_field(step.op, "is_enabled"))?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "constraint",
                [(
                    "isEnabled".to_string(),
                    Some(ComponentValue::Bool(is_enabled)),
                )],
            )])
        }

        SceneEditOp::SetColliderShape => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let shape_name = step
                .collider_shape
                .as_deref()
                .ok_or_else(|| missing_field(step.op, "collider_shape"))?;
            let kind = ColliderShapeKind::from_raw_value(shape_name).ok_or_else(|| {
                SceneEditPlanExecutorError::UnknownColliderShape(shape_name.to_string())
            })?;
            let mut collider = scene
                .component::<Collider>(entity)
                .unwrap_or_else(default_collider);
            let current = collider.shape();
            let shape = match kind {
                ColliderShapeKind::Box => match current {
                    ColliderShape::Box {
                        half_extents,
                        center,
                    } => ColliderShape::Box {
                        half_extents,
                        center,
                    },
                    _ => ColliderShape::Box {
                        half_extents: Float3::splat(0.5),
                        center: Float3::ZERO,
                    },
                },
                ColliderShapeKind::Sphere => match current {
                    ColliderShape::Sphere { radius, center } => {
                        ColliderShape::Sphere { radius, center }
                    }
                    _ => ColliderShape::Sphere {
                        radius: 0.5,
                        center: Float3::ZERO,
                    },
                },
                ColliderShapeKind::Capsule => match current {
                    ColliderShape::Capsule {
                        radius,
                        half_height,
                        center,
                    } => ColliderShape::Capsule {
                        radius,
                        half_height,
                        center,
                    },
                    _ => ColliderShape::Capsule {
                        radius: 0.25,
                        half_height: 0.5,
                        center: Float3::ZERO,
                    },
                },
                ColliderShapeKind::Cylinder => match current {
                    ColliderShape::Cylinder {
                        radius,
                        half_height,
                        center,
                    } => ColliderShape::Cylinder {
                        radius,
                        half_height,
                        center,
                    },
                    _ => ColliderShape::Cylinder {
                        radius: 0.5,
                        half_height: 0.5,
                        center: Float3::ZERO,
                    },
                },
                ColliderShapeKind::HeightField => match current {
                    ColliderShape::HeightField {
                        resource_id,
                        center,
                    } => ColliderShape::HeightField {
                        resource_id,
                        center,
                    },
                    _ => ColliderShape::HeightField {
                        resource_id: None,
                        center: Float3::ZERO,
                    },
                },
                ColliderShapeKind::Mesh => match current {
                    ColliderShape::Mesh {
                        resource_id,
                        center,
                    } => ColliderShape::Mesh {
                        resource_id,
                        center,
                    },
                    _ => ColliderShape::Mesh {
                        resource_id: None,
                        center: Float3::ZERO,
                    },
                },
                ColliderShapeKind::Convex => match current {
                    ColliderShape::Convex {
                        resource_id,
                        center,
                    } => ColliderShape::Convex {
                        resource_id,
                        center,
                    },
                    _ => ColliderShape::Convex {
                        resource_id: None,
                        center: Float3::ZERO,
                    },
                },
            };
            collider.set_shape(shape);
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetColliderBoxExtents => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let half_extents = simd3(step.half_extents.as_deref())
                .ok_or_else(|| missing_field(step.op, "half_extents"))?;
            let mut collider = scene.component::<Collider>(entity).unwrap_or_else(|| {
                Collider::with_shape(ColliderShape::Box {
                    half_extents,
                    center: Float3::ZERO,
                })
            });
            let center = match collider.shape() {
                ColliderShape::Box { center, .. } => center,
                _ => Float3::ZERO,
            };
            collider.set_shape(ColliderShape::Box {
                half_extents,
                center,
            });
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetColliderSphereRadius => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let radius = step
                .radius
                .ok_or_else(|| missing_field(step.op, "radius"))?;
            let mut collider = scene.component::<Collider>(entity).unwrap_or_else(|| {
                Collider::with_shape(ColliderShape::Sphere {
                    radius,
                    center: Float3::ZERO,
                })
            });
            let center = match collider.shape() {
                ColliderShape::Sphere { center, .. } => center,
                _ => Float3::ZERO,
            };
            collider.set_shape(ColliderShape::Sphere { radius, center });
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetColliderCapsule => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            if step.radius.is_none() && step.half_height.is_none() {
                return Err(missing_field(step.op, "radius or half_height"));
            }
            let mut collider = scene.component::<Collider>(entity).unwrap_or_else(|| {
                Collider::with_shape(ColliderShape::Capsule {
                    radius: 0.25,
                    half_height: 0.5,
                    center: Float3::ZERO,
                })
            });
            let mut capsule_radius = 0.25;
            let mut capsule_half_height = 0.5;
            let mut capsule_center = Float3::ZERO;
            if let ColliderShape::Capsule {
                radius,
                half_height,
                center,
            } = collider.shape()
            {
                capsule_radius = radius;
                capsule_half_height = half_height;
                capsule_center = center;
            }
            if let Some(radius) = step.radius {
                capsule_radius = radius;
            }
            if let Some(half_height) = step.half_height {
                capsule_half_height = half_height;
            }
            collider.set_shape(ColliderShape::Capsule {
                radius: capsule_radius,
                half_height: capsule_half_height,
                center: capsule_center,
            });
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetColliderMaterial => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            if step.friction.is_none() && step.restitution.is_none() && step.density.is_none() {
                return Err(missing_field(step.op, "friction, restitution, or density"));
            }
            let mut collider = scene
                .component::<Collider>(entity)
                .unwrap_or_else(default_collider);
            if let Some(friction) = step.friction {
                collider.material.friction = friction;
            }
            if let Some(restitution) = step.restitution {
                collider.material.restitution = restitution;
            }
            if let Some(density) = step.density {
                collider.material.density = density;
            }
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "collider",
                collider,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetAudioSource => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let mut source = scene.component::<AudioSource>(entity).unwrap_or_default();
            if let Some(clip) = &step.audio_clip {
                source.clip_name = clip.clone();
            }
            if let Some(volume) = step.audio_volume {
                source.volume = volume;
            }
            if let Some(pitch) = step.audio_pitch {
                source.pitch = pitch;
            }
            if let Some(loop_) = step.audio_loop {
                source.loop_ = loop_;
            }
            if let Some(play_on_awake) = step.audio_play_on_awake {
                source.play_on_awake = play_on_awake;
            }
            if let Some(spatial_blend) = step.audio_spatial_blend {
                source.spatial_blend = spatial_blend;
            }
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "audioSource",
                source,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetMeshVisibility => {
            let entity_id = resolve_entity_id(step, scene)?;
            let is_visible = step
                .is_visible
                .ok_or_else(|| missing_field(step.op, "is_visible"))?;
            Ok(vec![SceneMutation::component_fields(
                entity_id,
                "renderMesh",
                [(
                    "isVisible".to_string(),
                    Some(ComponentValue::Bool(is_visible)),
                )],
            )])
        }

        SceneEditOp::SetAnimationPlayer => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let mut player = scene
                .component::<AnimationPlayer>(entity)
                .unwrap_or_default();
            if let Some(clip) = &step.animation_clip {
                player.clip_name = if clip.is_empty() {
                    None
                } else {
                    Some(clip.clone())
                };
            }
            if let Some(speed) = step.animation_speed {
                player.speed = speed;
            }
            if let Some(loop_) = step.animation_loop {
                player.loop_ = loop_;
            }
            if let Some(is_playing) = step.animation_is_playing {
                player.is_playing = is_playing;
            }
            let player = AnimationPlayer::new(
                player.clip_name,
                player.speed,
                player.loop_,
                player.is_playing,
                0.0,
            );
            Ok(vec![SceneMutation::component_data(
                entity_id,
                "animationPlayer",
                player,
                ComponentRegistry::built_in(),
            )])
        }

        SceneEditOp::SetScriptProperty => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let property_name = step
                .script_property_name
                .as_deref()
                .filter(|name| !name.is_empty())
                .ok_or_else(|| missing_field(step.op, "script_property_name"))?;
            let property_value = step
                .script_property_value
                .as_ref()
                .ok_or_else(|| missing_field(step.op, "script_property_value"))?;
            let binding_index = step.script_index.unwrap_or(0);
            let mut component = scene
                .component::<ScriptComponent>(entity)
                .unwrap_or_default();
            if binding_index < 0 || binding_index as usize > component.bindings.len() {
                return Err(missing_field(step.op, "valid script_index"));
            }
            let index = binding_index as usize;
            if index == component.bindings.len() {
                let identifier = step
                    .script_identifier
                    .as_ref()
                    .ok_or_else(|| missing_field(step.op, "script_identifier"))?;
                component
                    .bindings
                    .push(ScriptBinding::with_identifier(identifier.clone()));
            } else if let Some(identifier) = &step.script_identifier {
                component.bindings[index].identifier = Some(identifier.clone());
                component.bindings[index].script = ScriptHandle::new(0);
            }
            component.bindings[index].parameters_json = merge_script_property(
                &component.bindings[index].parameters_json,
                property_name,
                property_value,
            );
            Ok(vec![script_mutation(entity_id, &component.bindings)])
        }

        SceneEditOp::SetScriptEnabled => {
            let entity_id = resolve_entity_id(step, scene)?;
            let entity = EntityID::from_raw_value(entity_id);
            let is_enabled = step
                .is_enabled
                .ok_or_else(|| missing_field(step.op, "is_enabled"))?;
            let binding_index = step.script_index.unwrap_or(0);
            let mut component = scene
                .component::<ScriptComponent>(entity)
                .unwrap_or_default();
            if binding_index < 0 || binding_index as usize > component.bindings.len() {
                return Err(missing_field(step.op, "valid script_index"));
            }
            let index = binding_index as usize;
            if index == component.bindings.len() {
                let identifier = step
                    .script_identifier
                    .as_ref()
                    .ok_or_else(|| missing_field(step.op, "script_identifier"))?;
                component.bindings.push(ScriptBinding::from_identifier(
                    identifier.clone(),
                    ScriptBindingID::new(),
                    is_enabled,
                    "{}",
                ));
            } else {
                if let Some(identifier) = &step.script_identifier {
                    component.bindings[index].identifier = Some(identifier.clone());
                    component.bindings[index].script = ScriptHandle::new(0);
                }
                component.bindings[index].is_enabled = is_enabled;
            }
            Ok(vec![script_mutation(entity_id, &component.bindings)])
        }
    }
}

fn merge_script_property(json: &str, key: &str, value: &JSONValue) -> String {
    let fallback = || format!("{{\"{key}\":{}}}", value.json_fragment());
    let Ok(mut object) = serde_json::from_str::<BTreeMap<String, Box<RawValue>>>(json) else {
        return fallback();
    };
    let Ok(raw) = RawValue::from_string(value.json_fragment()) else {
        return fallback();
    };
    object.insert(key.to_string(), raw);
    serde_json::to_string(&object).unwrap_or_else(|_| fallback())
}

fn script_mutation(entity_id: u64, bindings: &[ScriptBinding]) -> SceneMutation {
    SceneMutation::SetComponentData {
        entity_id,
        type_id: "script".to_string(),
        value: ComponentValue::Object(BTreeMap::from([(
            "bindings".to_string(),
            ComponentValue::Array(
                bindings
                    .iter()
                    .map(|binding| {
                        ComponentValue::Object(encode_script_binding_for_editing(binding))
                    })
                    .collect(),
            ),
        )])),
        mode: ComponentWriteMode::Replace,
    }
}

fn resolve_optional_ref(
    reference: Option<&str>,
    scene: &SceneRuntime,
) -> Result<Option<u64>, SceneEditPlanExecutorError> {
    reference
        .map(|reference| resolve_reference(reference, scene))
        .transpose()
}

fn resolve_entity_id(
    step: &SceneEditStep,
    scene: &SceneRuntime,
) -> Result<u64, SceneEditPlanExecutorError> {
    let reference = step
        .entity_ref
        .as_deref()
        .ok_or(SceneEditPlanExecutorError::MissingEntityRef { op: step.op })?;
    resolve_reference(reference, scene)
}

fn resolve_reference(
    reference: &str,
    scene: &SceneRuntime,
) -> Result<u64, SceneEditPlanExecutorError> {
    let raw = reference
        .strip_prefix("scene:")
        .and_then(|digits| digits.parse::<u64>().ok())
        .ok_or_else(|| SceneEditPlanExecutorError::InvalidEntityRef(reference.to_string()))?;
    if !scene.contains(EntityID::from_raw_value(raw)) {
        return Err(SceneEditPlanExecutorError::EntityNotFound(
            reference.to_string(),
        ));
    }
    Ok(raw)
}

fn missing_field(op: SceneEditOp, field: &str) -> SceneEditPlanExecutorError {
    SceneEditPlanExecutorError::MissingField {
        op,
        field: field.to_string(),
    }
}

fn invalid_capability_input(capability_id: &str, reason: String) -> SceneEditPlanExecutorError {
    SceneEditPlanExecutorError::InvalidCapabilityInput {
        capability_id: capability_id.to_string(),
        reason,
    }
}

fn simd3(values: Option<&[f32]>) -> Option<Float3> {
    values
        .filter(|values| values.len() >= 3)
        .map(|values| Float3::new(values[0], values[1], values[2]))
}

fn component_number(value: f32) -> ComponentValue {
    ComponentValue::Number(f64::from(value))
}

fn component_vector(value: Float3) -> ComponentValue {
    ComponentValue::Array(vec![
        component_number(value.x),
        component_number(value.y),
        component_number(value.z),
    ])
}

fn component_vector4(value: Float4) -> ComponentValue {
    ComponentValue::Array(vec![
        component_number(value.x),
        component_number(value.y),
        component_number(value.z),
        component_number(value.w),
    ])
}

fn texture_index_value(index: Option<i64>) -> ComponentValue {
    match index {
        Some(index) => ComponentValue::Number(index as f64),
        None => ComponentValue::Null,
    }
}

fn clamp_u16(value: i64) -> u16 {
    value.clamp(0, i64::from(u16::MAX)) as u16
}

fn default_collider() -> Collider {
    Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::splat(0.5),
        center: Float3::ZERO,
    })
}

fn default_render_material() -> RenderMaterialComponent {
    RenderMaterialComponent::new(
        Float4::ONE,
        None,
        None,
        0.0,
        1.0,
        Float3::ZERO,
        None,
        None,
        None,
    )
}

/// Builds a 4×4 rotation matrix from XYZ intrinsic Euler angles (degrees).
fn rotation_matrix(euler: Float3) -> Float4x4 {
    let to_radians = std::f32::consts::PI / 180.0;
    let rx = Float4x4::from_quatf(Quatf::from_angle_axis(
        euler.x * to_radians,
        Float3::new(1.0, 0.0, 0.0),
    ));
    let ry = Float4x4::from_quatf(Quatf::from_angle_axis(
        euler.y * to_radians,
        Float3::new(0.0, 1.0, 0.0),
    ));
    let rz = Float4x4::from_quatf(Quatf::from_angle_axis(
        euler.z * to_radians,
        Float3::new(0.0, 0.0, 1.0),
    ));
    rx * ry * rz
}

fn extract_scale(matrix: &Float4x4) -> Float3 {
    Float3::new(
        simd_length(Float3::new(
            matrix.columns[0].x,
            matrix.columns[0].y,
            matrix.columns[0].z,
        )),
        simd_length(Float3::new(
            matrix.columns[1].x,
            matrix.columns[1].y,
            matrix.columns[1].z,
        )),
        simd_length(Float3::new(
            matrix.columns[2].x,
            matrix.columns[2].y,
            matrix.columns[2].z,
        )),
    )
}

fn rotation_only(matrix: &Float4x4) -> Float4x4 {
    let scale = extract_scale(matrix);
    let mut rotation = *matrix;
    rotation.columns[0] = Float4::new(
        matrix.columns[0].x / scale.x,
        matrix.columns[0].y / scale.x,
        matrix.columns[0].z / scale.x,
        0.0,
    );
    rotation.columns[1] = Float4::new(
        matrix.columns[1].x / scale.y,
        matrix.columns[1].y / scale.y,
        matrix.columns[1].z / scale.y,
        0.0,
    );
    rotation.columns[2] = Float4::new(
        matrix.columns[2].x / scale.z,
        matrix.columns[2].y / scale.z,
        matrix.columns[2].z / scale.z,
        0.0,
    );
    rotation.columns[3] = Float4::new(0.0, 0.0, 0.0, 1.0);
    rotation
}

fn compose_matrix(translation: Float3, rotation: Float4x4, scale: Float3) -> Float4x4 {
    let mut matrix = rotation;
    matrix.columns[0] = matrix.columns[0] * scale.x;
    matrix.columns[1] = matrix.columns[1] * scale.y;
    matrix.columns[2] = matrix.columns[2] * scale.z;
    matrix.columns[3] = Float4::new(translation.x, translation.y, translation.z, 1.0);
    matrix
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use diffuse_capability::capability_contract::CapabilityExposureSnapshot;
    use diffuse_capability::support::swift_date::SwiftDate;
    use diffuse_intent::transactions::transaction_ir::{
        SceneMutation, TransactionOperation, TransactionProvenance,
        TransactionVerificationAssertion,
    };
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::components::core::value::ComponentValue;
    use diffuse_scene::entity_id::EntityID;
    use diffuse_scene::physics::collider::{Collider, ColliderShape};
    use diffuse_scene::scene_runtime::SceneRuntime;

    use super::{SceneEditPlanExecutor, SceneEditPlanExecutorError, canonical_capability_input};
    use crate::planning::scene_edit_plan::{SceneEditOp, SceneEditPlan, SceneEditStep};

    fn scene_with_entity() -> (SceneRuntime, String) {
        let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
        let entity = scene.create_entity();
        (scene, format!("scene:{}", entity.raw_value()))
    }

    fn plan(json: &str) -> SceneEditPlan {
        serde_json::from_str(json).expect("decode plan")
    }

    #[test]
    fn canonical_input_drops_op_and_sorts_keys() {
        let step: SceneEditStep = serde_json::from_str(
            r#"{"op":"set_light_intensity","entity_id":"scene:1","intensity":2.5}"#,
        )
        .expect("decode step");
        let input = canonical_capability_input(&step).expect("canonical input");
        assert_eq!(input.data, r#"{"entity_id":"scene:1","intensity":2.5}"#);
        assert_eq!(
            input.argument_names,
            vec!["entity_id".to_string(), "intensity".to_string()]
        );
    }

    #[test]
    fn spawn_prepares_a_typed_operation_and_invocation() {
        let scene = SceneRuntime::new(ComponentRegistry::built_in());
        let plan = plan(
            r#"{"summary":"spawn","steps":[
                {"op":"spawn_entity","label":"Box","spawn_kind":"empty"}
            ]}"#,
        );
        let transaction = SceneEditPlanExecutor::new()
            .build_transaction_with_defaults(&plan, &scene)
            .expect("build transaction");
        assert_eq!(transaction.provenance, TransactionProvenance::Proposal);
        assert!(matches!(
            transaction.operations.as_slice(),
            [TransactionOperation::Scene(
                SceneMutation::SpawnEmptyEntity { .. }
            )]
        ));
        assert_eq!(transaction.capability_invocations.len(), 1);
        let invocation = &transaction.capability_invocations[0];
        assert_eq!(invocation.capability_id, "scene.spawn_entity");
        assert_eq!(
            invocation.argument_names,
            vec!["label".to_string(), "spawn_kind".to_string()]
        );
        assert!(transaction.verification_assertions.iter().any(|assertion| {
            matches!(
                assertion,
                TransactionVerificationAssertion::CreatedEntityCount(1)
            )
        }));
    }

    #[test]
    fn an_unknown_entity_is_rejected_before_schema_validation() {
        let scene = SceneRuntime::new(ComponentRegistry::built_in());
        let plan = plan(
            r#"{"summary":"delete","steps":[
                {"op":"delete_entity","entity_id":"scene:999"}
            ]}"#,
        );
        let error = SceneEditPlanExecutor::new()
            .build_transaction_with_defaults(&plan, &scene)
            .expect_err("unknown entity");
        assert_eq!(
            error,
            SceneEditPlanExecutorError::EntityNotFound("scene:999".to_string())
        );
    }

    #[test]
    fn legacy_color_diagnostic_precedes_schema_validation() {
        let (scene, reference) = scene_with_entity();
        let plan = plan(&format!(
            r#"{{"summary":"color","steps":[
                {{"op":"set_light_color","entity_id":"{reference}","color":[1,0]}}
            ]}}"#
        ));
        let error = SceneEditPlanExecutor::new()
            .build_transaction_with_defaults(&plan, &scene)
            .expect_err("invalid color");
        assert_eq!(
            error,
            SceneEditPlanExecutorError::InvalidColor {
                op: SceneEditOp::SetLightColor
            }
        );
    }

    #[test]
    fn a_missing_contract_in_the_snapshot_is_unavailable() {
        let scene = SceneRuntime::new(ComponentRegistry::built_in());
        let plan = plan(
            r#"{"summary":"spawn","steps":[
                {"op":"spawn_entity","spawn_kind":"empty"}
            ]}"#,
        );
        let snapshot = CapabilityExposureSnapshot::new(
            diffuse_kernel::codable::new_uuid(),
            1,
            None,
            Vec::new(),
            SwiftDate::now(),
            BTreeMap::new(),
        );
        let error = SceneEditPlanExecutor::new()
            .build_transaction(
                &plan,
                &scene,
                None,
                diffuse_intent::transactions::transaction_ir::TransactionApprovalPolicy::Automatic,
                Some(&snapshot),
                &diffuse_intent::BuiltInTypedCapabilityCatalog::registry(),
            )
            .expect_err("missing contract");
        assert_eq!(
            error,
            SceneEditPlanExecutorError::CapabilityUnavailable("scene.spawn_entity".to_string())
        );
    }

    #[test]
    fn script_property_creates_a_binding_with_merged_parameters() {
        let (scene, reference) = scene_with_entity();
        let plan = plan(&format!(
            r#"{{"summary":"script","steps":[
                {{"op":"set_script_property","entity_id":"{reference}",
                  "script_identifier":"player","script_property_name":"speed",
                  "script_property_value":3.5}}
            ]}}"#
        ));
        let transaction = SceneEditPlanExecutor::new()
            .build_transaction_with_defaults(&plan, &scene)
            .expect("build transaction");
        let TransactionOperation::Scene(SceneMutation::SetComponentData { type_id, value, .. }) =
            &transaction.operations[0]
        else {
            panic!("expected a script component write");
        };
        assert_eq!(type_id, "script");
        let object = value.object_value().expect("component object");
        let bindings = object
            .get("bindings")
            .and_then(|bindings| bindings.as_array())
            .expect("bindings array");
        assert_eq!(bindings.len(), 1);
        let binding = bindings[0].object_value().expect("binding object");
        assert_eq!(
            binding
                .get("parametersJSON")
                .and_then(|value| value.as_str()),
            Some(r#"{"speed":3.5}"#)
        );
        assert_eq!(
            binding.get("identifier").and_then(|value| value.as_str()),
            Some("player")
        );
    }

    #[test]
    fn a_later_step_reads_the_shadow_scene() {
        let (mut scene, reference) = scene_with_entity();
        let collider = Collider::with_shape(ColliderShape::Box {
            half_extents: diffuse_math::simd::simd_compat::Float3::splat(0.5),
            center: diffuse_math::simd::simd_compat::Float3::ZERO,
        });
        let entity = EntityID::from_raw_value(
            reference
                .strip_prefix("scene:")
                .and_then(|digits| digits.parse::<u64>().ok())
                .expect("raw entity id"),
        );
        assert!(scene.set_component(collider, entity));
        let plan = plan(&format!(
            r#"{{"summary":"collider","steps":[
                {{"op":"set_collider_trigger","entity_id":"{reference}","is_trigger":true}},
                {{"op":"set_collider_sphere_radius","entity_id":"{reference}","radius":2.0}}
            ]}}"#
        ));
        let transaction = SceneEditPlanExecutor::new()
            .build_transaction_with_defaults(&plan, &scene)
            .expect("build transaction");
        let TransactionOperation::Scene(SceneMutation::SetComponentData { value, .. }) =
            &transaction.operations[1]
        else {
            panic!("expected a collider component write");
        };
        let object = value.object_value().expect("component object");
        assert_eq!(object.get("isTrigger"), Some(&ComponentValue::Bool(true)));
    }
}
