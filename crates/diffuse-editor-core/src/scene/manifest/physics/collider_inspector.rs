//! `Editor/Sources/EditorCore/Scene/Manifest/Physics/ColliderInspector.swift`.
//!
//! Inspector-side JSON round-trip for compound collider shapes. This is not part
//! of the scene document: the manifest stores colliders through the shared
//! serializer's component document, while the inspector exposes this lossless
//! text representation as a debug editing surface over `ColliderShapeInstance`.

use diffuse_scene::physics::collider::{ColliderShape, ColliderShapeInstance};
use serde::{Deserialize, Serialize};

use crate::scene::manifest::transform_math::{
    EditorSceneManifestVector3, EditorSceneManifestVector4,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifestColliderShape {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub half_extents: Option<EditorSceneManifestVector3>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "serialize_optional_float"
    )]
    pub radius: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "serialize_optional_float"
    )]
    pub half_height: Option<f32>,
    #[serde(
        rename = "resourceID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub resource_id: Option<String>,
    pub center: EditorSceneManifestVector3,
}

fn serialize_optional_float<S: serde::Serializer>(
    value: &Option<f32>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match value {
        Some(value) => diffuse_kernel::codable::serialize_float(value, serializer),
        None => serializer.serialize_none(),
    }
}

impl EditorSceneManifestColliderShape {
    pub fn new(shape: &ColliderShape) -> Self {
        match shape {
            ColliderShape::Box {
                half_extents,
                center,
            } => EditorSceneManifestColliderShape {
                kind: "box".to_string(),
                half_extents: Some(EditorSceneManifestVector3::from_simd(*half_extents)),
                radius: None,
                half_height: None,
                resource_id: None,
                center: EditorSceneManifestVector3::from_simd(*center),
            },
            ColliderShape::Sphere { radius, center } => EditorSceneManifestColliderShape {
                kind: "sphere".to_string(),
                half_extents: None,
                radius: Some(*radius),
                half_height: None,
                resource_id: None,
                center: EditorSceneManifestVector3::from_simd(*center),
            },
            ColliderShape::Capsule {
                radius,
                half_height,
                center,
            } => EditorSceneManifestColliderShape {
                kind: "capsule".to_string(),
                half_extents: None,
                radius: Some(*radius),
                half_height: Some(*half_height),
                resource_id: None,
                center: EditorSceneManifestVector3::from_simd(*center),
            },
            ColliderShape::Cylinder {
                radius,
                half_height,
                center,
            } => EditorSceneManifestColliderShape {
                kind: "cylinder".to_string(),
                half_extents: None,
                radius: Some(*radius),
                half_height: Some(*half_height),
                resource_id: None,
                center: EditorSceneManifestVector3::from_simd(*center),
            },
            ColliderShape::HeightField {
                resource_id,
                center,
            } => EditorSceneManifestColliderShape {
                kind: "heightField".to_string(),
                half_extents: None,
                radius: None,
                half_height: None,
                resource_id: resource_id.clone(),
                center: EditorSceneManifestVector3::from_simd(*center),
            },
            ColliderShape::Mesh {
                resource_id,
                center,
            } => EditorSceneManifestColliderShape {
                kind: "mesh".to_string(),
                half_extents: None,
                radius: None,
                half_height: None,
                resource_id: resource_id.clone(),
                center: EditorSceneManifestVector3::from_simd(*center),
            },
            ColliderShape::Convex {
                resource_id,
                center,
            } => EditorSceneManifestColliderShape {
                kind: "convex".to_string(),
                half_extents: None,
                radius: None,
                half_height: None,
                resource_id: resource_id.clone(),
                center: EditorSceneManifestVector3::from_simd(*center),
            },
        }
    }

    pub fn shape(&self) -> ColliderShape {
        let center = self.center.simd_value();
        match self.kind.as_str() {
            "box" => ColliderShape::Box {
                half_extents: self
                    .half_extents
                    .map(|value| value.simd_value())
                    .unwrap_or_else(|| diffuse_math::simd::simd_compat::Float3::new(0.5, 0.5, 0.5)),
                center,
            },
            "sphere" => ColliderShape::Sphere {
                radius: self.radius.unwrap_or(0.5),
                center,
            },
            "capsule" => ColliderShape::Capsule {
                radius: self.radius.unwrap_or(0.5),
                half_height: self.half_height.unwrap_or(0.5),
                center,
            },
            "cylinder" => ColliderShape::Cylinder {
                radius: self.radius.unwrap_or(0.5),
                half_height: self.half_height.unwrap_or(0.5),
                center,
            },
            "heightField" => ColliderShape::HeightField {
                resource_id: self.resource_id.clone(),
                center,
            },
            "mesh" => ColliderShape::Mesh {
                resource_id: self.resource_id.clone(),
                center,
            },
            "convex" => ColliderShape::Convex {
                resource_id: self.resource_id.clone(),
                center,
            },
            _ => ColliderShape::Box {
                half_extents: diffuse_math::simd::simd_compat::Float3::new(0.5, 0.5, 0.5),
                center,
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifestColliderShapeInstance {
    pub shape: EditorSceneManifestColliderShape,
    pub local_position: EditorSceneManifestVector3,
    pub local_rotation: EditorSceneManifestVector4,
    pub local_scale: EditorSceneManifestVector3,
}

impl EditorSceneManifestColliderShapeInstance {
    pub fn new(instance: &ColliderShapeInstance) -> Self {
        EditorSceneManifestColliderShapeInstance {
            shape: EditorSceneManifestColliderShape::new(&instance.shape),
            local_position: EditorSceneManifestVector3::from_simd(instance.local_position),
            local_rotation: EditorSceneManifestVector4::from_simd(instance.local_rotation),
            local_scale: EditorSceneManifestVector3::from_simd(instance.local_scale),
        }
    }

    pub fn instance(&self) -> ColliderShapeInstance {
        ColliderShapeInstance::with_transform(
            self.shape.shape(),
            self.local_position.simd_value(),
            self.local_rotation.simd_value(),
            self.local_scale.simd_value(),
        )
    }
}
