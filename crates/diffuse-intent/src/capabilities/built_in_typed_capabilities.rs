//! Typed scene primitives and the model-facing built-in capability catalog.

use std::sync::OnceLock;

use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::{self, JsonSchema};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, Quatf, simd_length};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::rendering::render_extraction::LightType;
use diffuse_scene::runtime_world::LocalTransform;
use serde::{Deserialize, Serialize};

use super::built_in_camera_material_capabilities::*;
use super::built_in_physics_capabilities::*;
use super::built_in_scene_utility_capabilities::*;
use super::cove_capability::{
    AnyCapabilityRegistration, CapabilityPreparationContext, CapabilityPreview, PreparedCapability,
    declare_capability,
};
use crate::invocation::capability_input_declaration::{
    CapabilitySchemaValue, SceneEntityRef, Vec3, Vec4, entity_reference_schema, field_schema,
};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionOperation, TransactionVerificationAssertion,
};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum BuiltInCapabilityPreparationError {
    #[error("entity '{0}' is unavailable in the capability preparation snapshot")]
    EntityNotFound(String),
    #[error("entity '{0}' has no local transform in the capability preparation snapshot")]
    LocalTransformUnavailable(String),
    #[error("set_transform requires at least one of position, euler_degrees, or scale")]
    NoTransformFields,
    #[error("set_name requires a non-empty name")]
    EmptyName,
    #[error("entity '{reference}' is missing required component '{component}'")]
    MissingRequiredComponent {
        reference: String,
        component: String,
    },
    #[error("field '{0}' contains a value outside the engine's finite Float range")]
    ValueOutOfFloatRange(String),
    #[error("set_light_spot_angles requires an inner or outer angle")]
    NoSpotAngleFields,
    #[error("spot_inner_angle cannot be greater than spot_outer_angle")]
    InvalidSpotAngleOrder,
}

pub(crate) fn prepared_entity_id(
    reference: &SceneEntityRef,
    requiring: Option<&str>,
    context: &CapabilityPreparationContext,
) -> Result<u64, BuiltInCapabilityPreparationError> {
    let entity = context
        .entities
        .iter()
        .find(|entity| entity.reference == reference.as_str())
        .ok_or_else(|| {
            BuiltInCapabilityPreparationError::EntityNotFound(reference.as_str().to_string())
        })?;
    let raw_id = reference
        .as_str()
        .strip_prefix("scene:")
        .and_then(|s| s.parse::<u64>().ok())
        .ok_or_else(|| {
            BuiltInCapabilityPreparationError::EntityNotFound(reference.as_str().to_string())
        })?;
    if let Some(component) = requiring
        && !entity.component_types.iter().any(|name| name == component)
    {
        return Err(
            BuiltInCapabilityPreparationError::MissingRequiredComponent {
                reference: reference.as_str().to_string(),
                component: component.to_string(),
            },
        );
    }
    Ok(raw_id)
}

pub(crate) fn capability_float(
    value: f64,
    field: &str,
) -> Result<f32, BuiltInCapabilityPreparationError> {
    let converted = value as f32;
    if !converted.is_finite() {
        return Err(BuiltInCapabilityPreparationError::ValueOutOfFloatRange(
            field.to_string(),
        ));
    }
    Ok(converted)
}

pub(crate) fn capability_vector(
    value: Vec3,
    field: &str,
) -> Result<Float3, BuiltInCapabilityPreparationError> {
    Ok(Float3::new(
        capability_float(value.x, field)?,
        capability_float(value.y, field)?,
        capability_float(value.z, field)?,
    ))
}

pub(crate) fn capability_vector4(
    value: Vec4,
    field: &str,
) -> Result<Float4, BuiltInCapabilityPreparationError> {
    Ok(Float4::new(
        capability_float(value.x, field)?,
        capability_float(value.y, field)?,
        capability_float(value.z, field)?,
        capability_float(value.w, field)?,
    ))
}

pub(crate) fn prepared_local_transform(
    reference: &SceneEntityRef,
    context: &CapabilityPreparationContext,
) -> Result<(u64, LocalTransform), BuiltInCapabilityPreparationError> {
    let entity_id = prepared_entity_id(reference, None, context)?;
    let snapshot = context
        .entities
        .iter()
        .find(|e| e.reference == reference.as_str())
        .and_then(|e| e.local_transform.as_ref())
        .filter(|snapshot| snapshot.column_major_matrix.len() == 16)
        .ok_or_else(|| {
            BuiltInCapabilityPreparationError::LocalTransformUnavailable(
                reference.as_str().to_string(),
            )
        })?;
    let v = &snapshot.column_major_matrix;
    let matrix = Float4x4::from_columns([
        Float4::new(v[0], v[1], v[2], v[3]),
        Float4::new(v[4], v[5], v[6], v[7]),
        Float4::new(v[8], v[9], v[10], v[11]),
        Float4::new(v[12], v[13], v[14], v[15]),
    ]);
    Ok((entity_id, LocalTransform::new(matrix)))
}

fn transform_rotation_matrix(euler_degrees: Float3) -> Float4x4 {
    let to_radians = std::f32::consts::PI / 180.0;
    let x = Float4x4::from_quatf(Quatf::from_angle_axis(
        euler_degrees.x * to_radians,
        Float3::new(1.0, 0.0, 0.0),
    ));
    let y = Float4x4::from_quatf(Quatf::from_angle_axis(
        euler_degrees.y * to_radians,
        Float3::new(0.0, 1.0, 0.0),
    ));
    let z = Float4x4::from_quatf(Quatf::from_angle_axis(
        euler_degrees.z * to_radians,
        Float3::new(0.0, 0.0, 1.0),
    ));
    x * y * z
}

fn transform_scale(matrix: Float4x4) -> Float3 {
    Float3::new(
        simd_length(matrix.columns[0].xyz()),
        simd_length(matrix.columns[1].xyz()),
        simd_length(matrix.columns[2].xyz()),
    )
}

fn transform_rotation_only(matrix: Float4x4) -> Float4x4 {
    let scale = transform_scale(matrix);
    let x = if scale.x > 1e-6 {
        matrix.columns[0].xyz() / scale.x
    } else {
        Float3::new(1.0, 0.0, 0.0)
    };
    let y = if scale.y > 1e-6 {
        matrix.columns[1].xyz() / scale.y
    } else {
        Float3::new(0.0, 1.0, 0.0)
    };
    let z = if scale.z > 1e-6 {
        matrix.columns[2].xyz() / scale.z
    } else {
        Float3::new(0.0, 0.0, 1.0)
    };
    Float4x4::from_columns([
        Float4::new(x.x, x.y, x.z, 0.0),
        Float4::new(y.x, y.y, y.z, 0.0),
        Float4::new(z.x, z.y, z.z, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

fn composed_transform_matrix(translation: Float3, rotation: Float4x4, scale: Float3) -> Float4x4 {
    let mut matrix = rotation;
    matrix.columns[0] *= scale.x;
    matrix.columns[1] *= scale.y;
    matrix.columns[2] *= scale.z;
    matrix.columns[3] = Float4::new(translation.x, translation.y, translation.z, 1.0);
    matrix
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CapabilityLightType {
    Directional,
    Point,
    Spot,
}

impl CapabilitySchemaValue for CapabilityLightType {
    fn capability_schema() -> JsonSchema {
        capsule_schema::string_enum(None, &["directional", "point", "spot"])
    }
    fn capability_placeholder() -> Self {
        Self::Point
    }
}

impl CapabilityLightType {
    pub fn runtime_value(self) -> LightType {
        match self {
            Self::Directional => LightType::Directional,
            Self::Point => LightType::Point,
            Self::Spot => LightType::Spot,
        }
    }
}

pub struct BuiltInTypedCapabilityCatalog;

impl BuiltInTypedCapabilityCatalog {
    pub fn registrations() -> &'static [AnyCapabilityRegistration] {
        static REGISTRATIONS: OnceLock<Vec<AnyCapabilityRegistration>> = OnceLock::new();
        REGISTRATIONS.get_or_init(|| {
            macro_rules! register {
                ($($capability:ty),* $(,)?) => {
                    vec![$(AnyCapabilityRegistration::new::<$capability>()
                        .unwrap_or_else(|error| panic!("invalid built-in capability declaration: {error}"))),*]
                };
            }
            register![SpawnEntityCapability, SetNameCapability, DeleteEntityCapability,
                DuplicateEntityCapability, ReparentEntityCapability, SetTransformCapability,
                SnapToGroundCapability, SetLightTypeCapability, SetLightIntensityCapability,
                SetLightColorCapability, SetLightRangeCapability, SetLightSpotAnglesCapability,
                SetLightCastShadowsCapability, SetCameraPoseCapability, SetCameraFOVCapability,
                SetCameraAspectRatioCapability, SetCameraActiveCapability, SetMeshColorCapability,
                SetMaterialCapability, SetMeshVisibilityCapability, SetRigidBodyMotionTypeCapability,
                SetRigidBodyMassCapability, SetRigidBodyGravityScaleCapability, SetRigidBodyAllowSleepCapability,
                SetColliderShapeCapability, SetColliderBoxExtentsCapability, SetColliderSphereRadiusCapability,
                SetColliderCapsuleCapability, SetColliderMaterialCapability, SetColliderTriggerCapability,
                SetColliderLayerCapability, SetConstraintEnabledCapability, SetAudioSourceCapability,
                SetScriptPropertyCapability, SetScriptBindingsCapability, SetAnimationPlayerCapability]
        })
    }

    pub fn registration(capability_id: &str) -> Option<AnyCapabilityRegistration> {
        Self::registrations()
            .iter()
            .find(|r| r.contract.id == capability_id)
            .cloned()
    }

    pub fn registry() -> CapabilityRegistry {
        static REGISTRY: OnceLock<CapabilityRegistry> = OnceLock::new();
        REGISTRY
            .get_or_init(|| {
                CapabilityRegistry::default_registry().replacing_contracts(
                    &Self::registrations()
                        .iter()
                        .map(|r| r.contract.clone())
                        .collect::<Vec<_>>(),
                )
            })
            .clone()
    }
}

fn prepared_single(
    entity_id: u64,
    reference: &SceneEntityRef,
    summary: &str,
    mutation: SceneMutation,
) -> PreparedCapability {
    PreparedCapability::new(
        vec![TransactionOperation::Scene(mutation)],
        CapabilityPreview::new(summary, vec![reference.as_str().to_string()]),
        vec![TransactionVerificationAssertion::EntityExists(entity_id)],
    )
}

pub(crate) fn component_number(value: f32) -> ComponentValue {
    ComponentValue::Number(f64::from(value))
}
pub(crate) fn component_vector(value: Float3) -> ComponentValue {
    ComponentValue::Array(vec![
        component_number(value.x),
        component_number(value.y),
        component_number(value.z),
    ])
}
pub(crate) fn component_vector4(value: Float4) -> ComponentValue {
    ComponentValue::Array(vec![
        component_number(value.x),
        component_number(value.y),
        component_number(value.z),
        component_number(value.w),
    ])
}

declare_capability! {
    SetNameCapability, SetNameInput,
    "scene.set_name", "Rename entity", "Set an entity's display name.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        name: String => field_schema::<String>(Some("New entity display name."), None, None, Some(1), Some(256), None)
    },
    |input, context| {
        if input.name.is_empty() {
            return Err(BuiltInCapabilityPreparationError::EmptyName.into());
        }
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Rename entity",
            SceneMutation::SetSceneName {
                entity_id: id,
                value: input.name,
            },
        ))
    }
}

declare_capability! {
    DeleteEntityCapability, DeleteEntityInput,
    "scene.delete_entity", "Delete entity", "Delete an entity and its authored scene state.", DestructiveWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[])
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(SceneMutation::DeleteEntity {
                entity_id: id,
            })],
            CapabilityPreview::new("Delete entity", vec![input.entity_id.as_str().to_string()]),
            vec![
                TransactionVerificationAssertion::DeletedEntity(id),
                TransactionVerificationAssertion::EntityIsAbsent(id),
            ],
        ))
    }
}

declare_capability! {
    DuplicateEntityCapability, DuplicateEntityInput,
    "scene.duplicate_entity", "Duplicate entity", "Duplicate an entity, optionally with a local-space offset.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        duplicate_offset: Option<Vec3> => field_schema::<Option<Vec3>>(Some("Optional local-space offset for the duplicate."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        let mutation = if let Some(offset) = input.duplicate_offset {
            SceneMutation::DuplicateEntityWithOffset {
                entity_id: id,
                position_offset: capability_vector(offset, "duplicate_offset")?,
            }
        } else {
            SceneMutation::DuplicateEntity { entity_id: id }
        };
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(mutation)],
            CapabilityPreview::new(
                "Duplicate entity",
                vec![input.entity_id.as_str().to_string()],
            ),
            vec![
                TransactionVerificationAssertion::EntityExists(id),
                TransactionVerificationAssertion::CreatedEntityCount(1),
            ],
        ))
    }
}

declare_capability! {
    SetTransformCapability, SetTransformInput,
    "scene.set_transform", "Set transform", "Set selected local transform fields without overwriting omitted fields.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LocalTransform"]),
        position: Option<Vec3> => field_schema::<Option<Vec3>>(Some("New local-space position in metres."), None, None, None, None, None),
        euler_degrees: Option<Vec3> => field_schema::<Option<Vec3>>(Some("XYZ intrinsic Euler rotation in degrees."), None, None, None, None, None),
        scale: Option<Vec3> => field_schema::<Option<Vec3>>(None, Some(0.001), Some(1000.0), None, None, None)
    },
    |input, context| {
        if input.position.is_none() && input.euler_degrees.is_none() && input.scale.is_none() {
            return Err(BuiltInCapabilityPreparationError::NoTransformFields.into());
        }
        let (id, mut transform) = prepared_local_transform(&input.entity_id, context)?;
        if let Some(position) = input.position {
            let p = capability_vector(position, "position")?;
            transform.matrix.columns[3] = Float4::new(p.x, p.y, p.z, 1.0);
        }
        if let Some(euler) = input.euler_degrees {
            transform.matrix = composed_transform_matrix(
                transform.translation(),
                transform_rotation_matrix(capability_vector(euler, "euler_degrees")?),
                transform_scale(transform.matrix),
            );
        }
        if let Some(scale) = input.scale {
            transform.matrix = composed_transform_matrix(
                transform.translation(),
                transform_rotation_only(transform.matrix),
                capability_vector(scale, "scale")?,
            );
        }
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set entity transform",
            SceneMutation::SetLocalTransform {
                entity_id: id,
                transform,
            },
        ))
    }
}

declare_capability! {
    SetLightTypeCapability, SetLightTypeInput,
    "scene.set_light_type", "Set light type", "Change a light to directional, point, or spot.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LightComponent"]),
        light_type: CapabilityLightType => field_schema::<CapabilityLightType>(Some("New light type."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("LightComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set light type",
            SceneMutation::component_fields(
                id,
                "light",
                [(
                    "type".to_string(),
                    Some(ComponentValue::String(
                        input.light_type.runtime_value().raw_value().to_string(),
                    )),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetLightIntensityCapability, SetLightIntensityInput,
    "scene.set_light_intensity", "Set light intensity", "Set non-negative light intensity.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LightComponent"]),
        intensity: f64 => field_schema::<f64>(None, Some(0.0), None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("LightComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set light intensity",
            SceneMutation::component_fields(
                id,
                "light",
                [(
                    "intensity".to_string(),
                    Some(component_number(capability_float(
                        input.intensity,
                        "intensity",
                    )?)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetLightColorCapability, SetLightColorInput,
    "scene.set_light_color", "Set light colour", "Set linear RGB light colour.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LightComponent"]),
        color: Vec3 => field_schema::<Vec3>(None, Some(0.0), Some(1.0), None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("LightComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set light colour",
            SceneMutation::component_fields(
                id,
                "light",
                [(
                    "color".to_string(),
                    Some(component_vector(capability_vector(input.color, "color")?)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetLightRangeCapability, SetLightRangeInput,
    "scene.set_light_range", "Set light range", "Set non-negative light range in metres.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LightComponent"]),
        range: f64 => field_schema::<f64>(None, Some(0.0), None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("LightComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set light range",
            SceneMutation::component_fields(
                id,
                "light",
                [(
                    "range".to_string(),
                    Some(component_number(capability_float(input.range, "range")?)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetLightSpotAnglesCapability, SetLightSpotAnglesInput,
    "scene.set_light_spot_angles", "Set spot angles", "Set the spot light inner and outer cone angles.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LightComponent"]),
        spot_inner_angle: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(179.0), None, None, None),
        spot_outer_angle: Option<f64> => field_schema::<Option<f64>>(None, Some(1.0), Some(179.0), None, None, None)
    },
    |input, context| {
        if input.spot_inner_angle.is_none() && input.spot_outer_angle.is_none() {
            return Err(BuiltInCapabilityPreparationError::NoSpotAngleFields.into());
        }
        let current_outer = context
            .entities
            .iter()
            .find(|e| e.reference == input.entity_id.as_str())
            .and_then(|e| e.light.as_ref())
            .map(|light| f64::from(light.spot_outer_angle_degrees));
        if let (Some(inner), Some(outer)) = (
            input.spot_inner_angle,
            input.spot_outer_angle.or(current_outer),
        ) && inner > outer
        {
            return Err(BuiltInCapabilityPreparationError::InvalidSpotAngleOrder.into());
        }
        let id = prepared_entity_id(&input.entity_id, Some("LightComponent"), context)?;
        let mut operations = Vec::new();
        // Outer precedes inner to avoid clamping against the previous cone.
        if let Some(outer) = input.spot_outer_angle {
            operations.push(TransactionOperation::Scene(
                SceneMutation::component_fields(
                    id,
                    "light",
                    [(
                        "spotOuterAngleDegrees".to_string(),
                        Some(component_number(capability_float(
                            outer,
                            "spot_outer_angle",
                        )?)),
                    )],
                ),
            ));
        }
        if let Some(inner) = input.spot_inner_angle {
            operations.push(TransactionOperation::Scene(
                SceneMutation::component_fields(
                    id,
                    "light",
                    [(
                        "spotInnerAngleDegrees".to_string(),
                        Some(component_number(capability_float(
                            inner,
                            "spot_inner_angle",
                        )?)),
                    )],
                ),
            ));
        }
        Ok(PreparedCapability::new(
            operations,
            CapabilityPreview::new(
                "Set spot light angles",
                vec![input.entity_id.as_str().to_string()],
            ),
            vec![TransactionVerificationAssertion::EntityExists(id)],
        ))
    }
}

declare_capability! {
    SetLightCastShadowsCapability, SetLightCastShadowsInput,
    "scene.set_light_cast_shadows", "Set light shadows", "Enable or disable shadow casting for a light.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LightComponent"]),
        light_cast_shadows: bool => field_schema::<bool>(Some("Whether the light casts shadows."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("LightComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set light shadow casting",
            SceneMutation::component_fields(
                id,
                "light",
                [(
                    "castShadows".to_string(),
                    Some(ComponentValue::Bool(input.light_cast_shadows)),
                )],
            ),
        ))
    }
}
