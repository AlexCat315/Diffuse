//! Camera pose and material edits prepared from an immutable scene snapshot.

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_length_squared};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::rendering::render_extraction::RenderMaterialComponent;
use diffuse_scene::runtime_world::LocalTransform;

use super::built_in_typed_capabilities::{
    BuiltInCapabilityPreparationError, capability_float, capability_vector, capability_vector4,
    component_number, component_vector, component_vector4, prepared_entity_id,
};
use super::cove_capability::{
    CapabilityPreparationMaterial, CapabilityPreview, PreparedCapability, declare_capability,
};
use crate::invocation::capability_input_declaration::{
    SceneEntityRef, Vec3, Vec4, entity_reference_schema, field_schema,
};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionOperation, TransactionVerificationAssertion,
};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CameraMaterialCapabilityPreparationError {
    #[error("camera position and target must be different")]
    CoincidentCameraPositionAndTarget,
    #[error("camera_up must be a non-zero vector")]
    InvalidCameraUp,
    #[error("set_material requires at least one material field")]
    NoMaterialFields,
    #[error("entity '{0}' has no usable material preparation snapshot")]
    MaterialSnapshotUnavailable(String),
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

declare_capability! {
    SetCameraPoseCapability, SetCameraPoseInput,
    "scene.set_camera_pose", "Set camera pose", "Set camera position, look-at target, and optional up vector.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["CameraComponent"]),
        position: Vec3 => field_schema::<Vec3>(Some("Camera local-space position in metres."), None, None, None, None, None),
        camera_target: Vec3 => field_schema::<Vec3>(Some("World-space point the camera looks at."), None, None, None, None, None),
        camera_up: Option<Vec3> => field_schema::<Option<Vec3>>(Some("Optional world-space camera up vector."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("CameraComponent"), context)?;
        let position = capability_vector(input.position, "position")?;
        let target = capability_vector(input.camera_target, "camera_target")?;
        if simd_length_squared(target - position).partial_cmp(&1e-12)
            != Some(std::cmp::Ordering::Greater)
        {
            return Err(
                CameraMaterialCapabilityPreparationError::CoincidentCameraPositionAndTarget.into(),
            );
        }
        let up = input
            .camera_up
            .map(|up| capability_vector(up, "camera_up"))
            .transpose()?;
        if let Some(up) = up
            && simd_length_squared(up) <= 1e-12
        {
            return Err(CameraMaterialCapabilityPreparationError::InvalidCameraUp.into());
        }
        Ok(PreparedCapability::new(
            vec![
                TransactionOperation::Scene(SceneMutation::SetLocalTransform {
                    entity_id: id,
                    transform: LocalTransform::from_translation(position),
                }),
                TransactionOperation::Scene(SceneMutation::component_fields(
                    id,
                    "camera",
                    [
                        ("target".to_string(), Some(component_vector(target))),
                        ("up".to_string(), up.map(component_vector)),
                    ],
                )),
            ],
            CapabilityPreview::new(
                "Set camera pose",
                vec![input.entity_id.as_str().to_string()],
            ),
            vec![TransactionVerificationAssertion::EntityExists(id)],
        ))
    }
}

declare_capability! {
    SetCameraFOVCapability, SetCameraFOVInput,
    "scene.set_camera_fov", "Set camera FOV", "Set vertical camera field of view in degrees.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["CameraComponent"]),
        camera_fov_y: f64 => field_schema::<f64>(None, Some(1.0), Some(179.0), None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("CameraComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set camera field of view",
            SceneMutation::component_fields(
                id,
                "camera",
                [(
                    "fovYRadians".to_string(),
                    Some(component_number(
                        capability_float(input.camera_fov_y, "camera_fov_y")? * std::f32::consts::PI
                            / 180.0,
                    )),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetCameraAspectRatioCapability, SetCameraAspectRatioInput,
    "scene.set_camera_aspect_ratio", "Set camera aspect ratio", "Set the authored camera width-to-height ratio.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["CameraComponent"]),
        camera_aspect_ratio: f64 => field_schema::<f64>(None, Some(0.01), Some(100.0), None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("CameraComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set camera aspect ratio",
            SceneMutation::component_fields(
                id,
                "camera",
                [(
                    "aspectRatio".to_string(),
                    Some(component_number(capability_float(
                        input.camera_aspect_ratio,
                        "camera_aspect_ratio",
                    )?)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetCameraActiveCapability, SetCameraActiveInput,
    "scene.set_camera_active", "Set camera active", "Enable or disable this camera as an active render camera.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["CameraComponent"]),
        camera_is_active: bool => field_schema::<bool>(Some("Whether this camera is active for rendering."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("CameraComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set camera active state",
            SceneMutation::component_fields(
                id,
                "camera",
                [(
                    "isActive".to_string(),
                    Some(ComponentValue::Bool(input.camera_is_active)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetMaterialCapability, SetMaterialInput,
    "scene.set_material", "Set PBR material", "Update selected PBR material fields while preserving omitted values.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        material_base_color: Option<Vec4> => field_schema::<Option<Vec4>>(None, Some(0.0), Some(1.0), None, None, None),
        material_metallic: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(1.0), None, None, None),
        material_roughness: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(1.0), None, None, None),
        material_emissive: Option<Vec3> => field_schema::<Option<Vec3>>(None, Some(0.0), Some(1.0), None, None, None)
    },
    |input, context| {
        if input.material_base_color.is_none()
            && input.material_metallic.is_none()
            && input.material_roughness.is_none()
            && input.material_emissive.is_none()
        {
            return Err(CameraMaterialCapabilityPreparationError::NoMaterialFields.into());
        }
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        let entity = context
            .entities
            .iter()
            .find(|e| e.reference == input.entity_id.as_str())
            .ok_or_else(|| {
                BuiltInCapabilityPreparationError::EntityNotFound(input.entity_id.as_str().to_string())
            })?;
        let snapshot = entity
            .render_material
            .clone()
            .or_else(|| {
                CapabilityPreparationMaterial::new(
                    vec![1.0, 1.0, 1.0, 1.0],
                    None,
                    None,
                    0.0,
                    1.0,
                    vec![0.0, 0.0, 0.0],
                )
            })
            .ok_or_else(|| {
                CameraMaterialCapabilityPreparationError::MaterialSnapshotUnavailable(
                    input.entity_id.as_str().to_string(),
                )
            })?;
        let mut base_color = Float4::new(
            snapshot.base_color[0],
            snapshot.base_color[1],
            snapshot.base_color[2],
            snapshot.base_color[3],
        );
        let mut metallic = snapshot.metallic;
        let mut roughness = snapshot.roughness;
        let mut emissive = Float3::new(
            snapshot.emissive[0],
            snapshot.emissive[1],
            snapshot.emissive[2],
        );
        if let Some(value) = input.material_base_color {
            base_color = capability_vector4(value, "material_base_color")?;
        }
        if let Some(value) = input.material_metallic {
            metallic = capability_float(value, "material_metallic")?;
        }
        if let Some(value) = input.material_roughness {
            roughness = capability_float(value, "material_roughness")?;
        }
        if let Some(value) = input.material_emissive {
            emissive = capability_vector(value, "material_emissive")?;
        }
        if entity.render_material.is_none() {
            let material = RenderMaterialComponent::new(
                base_color,
                snapshot.base_color_texture_index,
                snapshot.normal_texture_index,
                metallic,
                roughness,
                emissive,
                None,
                None,
                None,
            );
            return Ok(prepared_single(
                id,
                &input.entity_id,
                "Set PBR material",
                SceneMutation::component_data(
                    id,
                    "renderMaterial",
                    material,
                    ComponentRegistry::built_in(),
                ),
            ));
        }
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set PBR material",
            SceneMutation::component_fields(
                id,
                "renderMaterial",
                [
                    (
                        "baseColorFactor".to_string(),
                        Some(component_vector4(base_color)),
                    ),
                    (
                        "baseColorTextureIndex".to_string(),
                        Some(
                            snapshot
                                .base_color_texture_index
                                .map(|v| ComponentValue::Number(v as f64))
                                .unwrap_or(ComponentValue::Null),
                        ),
                    ),
                    (
                        "normalTextureIndex".to_string(),
                        Some(
                            snapshot
                                .normal_texture_index
                                .map(|v| ComponentValue::Number(v as f64))
                                .unwrap_or(ComponentValue::Null),
                        ),
                    ),
                    (
                        "metallicFactor".to_string(),
                        Some(component_number(metallic)),
                    ),
                    (
                        "roughnessFactor".to_string(),
                        Some(component_number(roughness)),
                    ),
                    (
                        "emissiveFactor".to_string(),
                        Some(component_vector(emissive)),
                    ),
                ],
            ),
        ))
    }
}
