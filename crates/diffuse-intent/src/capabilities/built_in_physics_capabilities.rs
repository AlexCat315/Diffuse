//! Rigid-body and collider edits prepared without mutating the live scene.

use diffuse_capability::capsule_schema::{self, JsonSchema};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::collider::{Collider, ColliderShape, ColliderShapeKind};
use diffuse_scene::physics::rigid_body::RigidBodyMotionType;
use serde::{Deserialize, Serialize};

use super::built_in_typed_capabilities::{
    BuiltInCapabilityPreparationError, capability_float, capability_vector, prepared_entity_id,
};
use super::cove_capability::{
    CapabilityPreparationContext, CapabilityPreparationEntity, CapabilityPreview,
    PreparedCapability, declare_capability,
};
use crate::invocation::capability_input_declaration::{
    CapabilitySchemaValue, SceneEntityRef, Vec3, entity_reference_schema, field_schema,
};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionOperation, TransactionVerificationAssertion,
};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PhysicsCapabilityPreparationError {
    #[error("set_collider_capsule requires radius or half_height")]
    NoCapsuleFields,
    #[error("set_collider_material requires friction, restitution, or density")]
    NoMaterialFields,
    #[error("set_collider_layer requires collider_layer_id or collider_layer_mask")]
    NoLayerFields,
}

fn prepared_physics_entity<'a>(
    reference: &SceneEntityRef,
    context: &'a CapabilityPreparationContext,
) -> Result<(u64, &'a CapabilityPreparationEntity), BuiltInCapabilityPreparationError> {
    let id = prepared_entity_id(reference, None, context)?;
    let entity = context
        .entities
        .iter()
        .find(|e| e.reference == reference.as_str())
        .ok_or_else(|| {
            BuiltInCapabilityPreparationError::EntityNotFound(reference.as_str().to_string())
        })?;
    Ok((id, entity))
}

fn default_collider() -> Collider {
    Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::splat(0.5),
        center: Float3::ZERO,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CapabilityRigidBodyMotionType {
    Static,
    Dynamic,
    Kinematic,
}

impl CapabilitySchemaValue for CapabilityRigidBodyMotionType {
    fn capability_schema() -> JsonSchema {
        capsule_schema::string_enum(None, &["static", "dynamic", "kinematic"])
    }
    fn capability_placeholder() -> Self {
        Self::Dynamic
    }
}

impl CapabilityRigidBodyMotionType {
    pub fn runtime_value(self) -> RigidBodyMotionType {
        match self {
            Self::Static => RigidBodyMotionType::Static,
            Self::Dynamic => RigidBodyMotionType::Dynamic,
            Self::Kinematic => RigidBodyMotionType::Kinematic,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CapabilityColliderShape {
    Box,
    Sphere,
    Capsule,
    Cylinder,
    HeightField,
    Mesh,
    Convex,
}

impl CapabilitySchemaValue for CapabilityColliderShape {
    fn capability_schema() -> JsonSchema {
        capsule_schema::string_enum(
            None,
            &[
                "box",
                "sphere",
                "capsule",
                "cylinder",
                "heightField",
                "mesh",
                "convex",
            ],
        )
    }
    fn capability_placeholder() -> Self {
        Self::Box
    }
}

impl CapabilityColliderShape {
    pub fn runtime_value(self) -> ColliderShapeKind {
        match self {
            Self::Box => ColliderShapeKind::Box,
            Self::Sphere => ColliderShapeKind::Sphere,
            Self::Capsule => ColliderShapeKind::Capsule,
            Self::Cylinder => ColliderShapeKind::Cylinder,
            Self::HeightField => ColliderShapeKind::HeightField,
            Self::Mesh => ColliderShapeKind::Mesh,
            Self::Convex => ColliderShapeKind::Convex,
        }
    }
}

fn physics_prepared(
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

declare_capability! {
    SetRigidBodyMotionTypeCapability, SetRigidBodyMotionTypeInput,
    "scene.set_rigid_body_motion_type", "Set rigid body motion", "Create or update a rigid body with static, dynamic, or kinematic motion.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        motion_type: CapabilityRigidBodyMotionType => field_schema::<CapabilityRigidBodyMotionType>(Some("Static, dynamic, or kinematic rigid-body motion."), None, None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut body = entity.rigid_body.clone().unwrap_or_default();
        body.motion_type = input.motion_type.runtime_value();
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set rigid body motion",
            SceneMutation::component_data(id, "rigidbody", body, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetRigidBodyMassCapability, SetRigidBodyMassInput,
    "scene.set_rigid_body_mass", "Set rigid body mass", "Create or update a rigid body's positive mass in kilograms.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        mass: f64 => field_schema::<f64>(None, Some(0.0001), None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut body = entity.rigid_body.clone().unwrap_or_default();
        body.mass = capability_float(input.mass, "mass")?;
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set rigid body mass",
            SceneMutation::component_data(id, "rigidbody", body, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetRigidBodyGravityScaleCapability, SetRigidBodyGravityScaleInput,
    "scene.set_rigid_body_gravity_scale", "Set rigid body gravity scale", "Create or update a rigid body's gravity multiplier.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        gravity_scale: f64 => field_schema::<f64>(Some("Multiplier applied to scene gravity."), None, None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut body = entity.rigid_body.clone().unwrap_or_default();
        body.gravity_scale = capability_float(input.gravity_scale, "gravity_scale")?;
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set rigid body gravity scale",
            SceneMutation::component_data(id, "rigidbody", body, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetRigidBodyAllowSleepCapability, SetRigidBodyAllowSleepInput,
    "scene.set_rigid_body_allow_sleep", "Set rigid body sleeping", "Create or update whether a rigid body may sleep.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        allow_sleep: bool => field_schema::<bool>(Some("Whether the rigid body may enter the sleeping state."), None, None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut body = entity.rigid_body.clone().unwrap_or_default();
        body.allow_sleep = input.allow_sleep;
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set rigid body sleeping",
            SceneMutation::component_data(id, "rigidbody", body, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderShapeCapability, SetColliderShapeInput,
    "scene.set_collider_shape", "Set collider shape", "Create or update the primary collider shape.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        collider_shape: CapabilityColliderShape => field_schema::<CapabilityColliderShape>(Some("Collider shape kind."), None, None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        let current = collider.shape();
        let shape = match input.collider_shape.runtime_value() {
            ColliderShapeKind::Box => {
                if let ColliderShape::Box {
                    half_extents,
                    center,
                } = current
                {
                    ColliderShape::Box {
                        half_extents,
                        center,
                    }
                } else {
                    ColliderShape::Box {
                        half_extents: Float3::splat(0.5),
                        center: Float3::ZERO,
                    }
                }
            }
            ColliderShapeKind::Sphere => {
                if let ColliderShape::Sphere { radius, center } = current {
                    ColliderShape::Sphere { radius, center }
                } else {
                    ColliderShape::Sphere {
                        radius: 0.5,
                        center: Float3::ZERO,
                    }
                }
            }
            ColliderShapeKind::Capsule => {
                if let ColliderShape::Capsule {
                    radius,
                    half_height,
                    center,
                } = current
                {
                    ColliderShape::Capsule {
                        radius,
                        half_height,
                        center,
                    }
                } else {
                    ColliderShape::Capsule {
                        radius: 0.25,
                        half_height: 0.5,
                        center: Float3::ZERO,
                    }
                }
            }
            ColliderShapeKind::Cylinder => {
                if let ColliderShape::Cylinder {
                    radius,
                    half_height,
                    center,
                } = current
                {
                    ColliderShape::Cylinder {
                        radius,
                        half_height,
                        center,
                    }
                } else {
                    ColliderShape::Cylinder {
                        radius: 0.5,
                        half_height: 0.5,
                        center: Float3::ZERO,
                    }
                }
            }
            ColliderShapeKind::HeightField => {
                if let ColliderShape::HeightField {
                    resource_id,
                    center,
                } = current
                {
                    ColliderShape::HeightField {
                        resource_id,
                        center,
                    }
                } else {
                    ColliderShape::HeightField {
                        resource_id: None,
                        center: Float3::ZERO,
                    }
                }
            }
            ColliderShapeKind::Mesh => {
                if let ColliderShape::Mesh {
                    resource_id,
                    center,
                } = current
                {
                    ColliderShape::Mesh {
                        resource_id,
                        center,
                    }
                } else {
                    ColliderShape::Mesh {
                        resource_id: None,
                        center: Float3::ZERO,
                    }
                }
            }
            ColliderShapeKind::Convex => {
                if let ColliderShape::Convex {
                    resource_id,
                    center,
                } = current
                {
                    ColliderShape::Convex {
                        resource_id,
                        center,
                    }
                } else {
                    ColliderShape::Convex {
                        resource_id: None,
                        center: Float3::ZERO,
                    }
                }
            }
        };
        collider.set_shape(shape);
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set collider shape",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderBoxExtentsCapability, SetColliderBoxExtentsInput,
    "scene.set_collider_box_extents", "Set box collider extents", "Create a box collider or update its positive half extents.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        half_extents: Vec3 => field_schema::<Vec3>(None, Some(0.0001), None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        let center = if let ColliderShape::Box { center, .. } = collider.shape() {
            center
        } else {
            Float3::ZERO
        };
        collider.set_shape(ColliderShape::Box {
            half_extents: capability_vector(input.half_extents, "half_extents")?,
            center,
        });
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set box collider extents",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderSphereRadiusCapability, SetColliderSphereRadiusInput,
    "scene.set_collider_sphere_radius", "Set sphere collider radius", "Create a sphere collider or update its positive radius.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        radius: f64 => field_schema::<f64>(None, Some(0.0001), None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        let center = if let ColliderShape::Sphere { center, .. } = collider.shape() {
            center
        } else {
            Float3::ZERO
        };
        collider.set_shape(ColliderShape::Sphere {
            radius: capability_float(input.radius, "radius")?,
            center,
        });
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set sphere collider radius",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderCapsuleCapability, SetColliderCapsuleInput,
    "scene.set_collider_capsule", "Set capsule collider dimensions", "Create a capsule collider or update selected positive dimensions.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        radius: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0001), None, None, None, None),
        half_height: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0001), None, None, None, None)
    },
    |input, context| {
        if input.radius.is_none() && input.half_height.is_none() {
            return Err(PhysicsCapabilityPreparationError::NoCapsuleFields.into());
        }
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        let (mut radius, mut half_height, center) = if let ColliderShape::Capsule {
            radius,
            half_height,
            center,
        } = collider.shape()
        {
            (radius, half_height, center)
        } else {
            (0.25, 0.5, Float3::ZERO)
        };
        if let Some(value) = input.radius {
            radius = capability_float(value, "radius")?;
        }
        if let Some(value) = input.half_height {
            half_height = capability_float(value, "half_height")?;
        }
        collider.set_shape(ColliderShape::Capsule {
            radius,
            half_height,
            center,
        });
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set capsule collider dimensions",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderMaterialCapability, SetColliderMaterialInput,
    "scene.set_collider_material", "Set collider material", "Create or update selected collider material fields.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        friction: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(1.0), None, None, None),
        restitution: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(1.0), None, None, None),
        density: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), None, None, None, None)
    },
    |input, context| {
        if input.friction.is_none() && input.restitution.is_none() && input.density.is_none() {
            return Err(PhysicsCapabilityPreparationError::NoMaterialFields.into());
        }
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        if let Some(value) = input.friction {
            collider.material.friction = capability_float(value, "friction")?;
        }
        if let Some(value) = input.restitution {
            collider.material.restitution = capability_float(value, "restitution")?;
        }
        if let Some(value) = input.density {
            collider.material.density = capability_float(value, "density")?;
        }
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set collider material",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderTriggerCapability, SetColliderTriggerInput,
    "scene.set_collider_trigger", "Set collider trigger", "Create or update collider trigger behaviour.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        is_trigger: bool => field_schema::<bool>(Some("Whether the collider behaves as a trigger."), None, None, None, None, None)
    },
    |input, context| {
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        collider.is_trigger = input.is_trigger;
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set collider trigger",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetColliderLayerCapability, SetColliderLayerInput,
    "scene.set_collider_layer", "Set collider layers", "Create or update collider layer id and interaction mask.", ReversibleWrite, Beta,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        collider_layer_id: Option<i64> => field_schema::<Option<i64>>(None, Some(0.0), Some(15.0), None, None, None),
        collider_layer_mask: Option<i64> => field_schema::<Option<i64>>(None, Some(0.0), Some(65535.0), None, None, None)
    },
    |input, context| {
        if input.collider_layer_id.is_none() && input.collider_layer_mask.is_none() {
            return Err(PhysicsCapabilityPreparationError::NoLayerFields.into());
        }
        let (id, entity) = prepared_physics_entity(&input.entity_id, context)?;
        let mut collider = entity.collider.clone().unwrap_or_else(default_collider);
        if let Some(value) = input.collider_layer_id {
            collider.layer_id = u16::try_from(value).expect("collider layer ID must fit UInt16");
        }
        if let Some(value) = input.collider_layer_mask {
            collider.layer_mask = u16::try_from(value).expect("collider layer mask must fit UInt16");
        }
        Ok(physics_prepared(
            id,
            &input.entity_id,
            "Set collider layers",
            SceneMutation::component_data(id, "collider", collider, ComponentRegistry::built_in()),
        ))
    }
}
