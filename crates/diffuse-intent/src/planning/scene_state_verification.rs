//! Authored-state snapshots used by post-apply verification.
//!
//! Each `…VerificationState` mirrors an authored component as **plain data** — floats in
//! arrays, enums in strings — so an assertion can be recorded, compared and serialized
//! without depending on the component's own type. That is deliberate: the snapshot must
//! stay comparable even when the component gains fields.
//!
//! Array layouts are part of the format: vectors are `[x, y, z]`, quaternions
//! `[x, y, z, w]`, and matrices are the four columns flattened in order.

use diffuse_scene::physics::collider::{Collider, ColliderShape};
use serde::{Deserialize, Serialize};

/// Flatten a matrix the way Swift's `verificationArray` did: columns in order.
pub fn matrix_verification_array(matrix: &diffuse_math::simd::simd_compat::Float4x4) -> Vec<f32> {
    let mut values = Vec::with_capacity(16);
    for column in matrix.columns {
        values.push(column.x);
        values.push(column.y);
        values.push(column.z);
        values.push(column.w);
    }
    values
}

fn vector_array(value: diffuse_math::simd::simd_compat::Float3) -> Vec<f32> {
    vec![value.x, value.y, value.z]
}

/// A collider's primary shape, as verified.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum SceneColliderShapeVerificationState {
    Box {
        half_extents: Vec<f32>,
        center: Vec<f32>,
    },
    Sphere {
        radius: f32,
        center: Vec<f32>,
    },
    Capsule {
        radius: f32,
        half_height: f32,
        center: Vec<f32>,
    },
    Cylinder {
        radius: f32,
        half_height: f32,
        center: Vec<f32>,
    },
    HeightField {
        resource_id: Option<String>,
        center: Vec<f32>,
    },
    Mesh {
        resource_id: Option<String>,
        center: Vec<f32>,
    },
    Convex {
        resource_id: Option<String>,
        center: Vec<f32>,
    },
}

impl SceneColliderShapeVerificationState {
    /// Snapshot a collider shape.
    pub fn from_shape(shape: &ColliderShape) -> Self {
        match shape {
            ColliderShape::Box {
                half_extents,
                center,
            } => SceneColliderShapeVerificationState::Box {
                half_extents: vector_array(*half_extents),
                center: vector_array(*center),
            },
            ColliderShape::Sphere { radius, center } => {
                SceneColliderShapeVerificationState::Sphere {
                    radius: *radius,
                    center: vector_array(*center),
                }
            }
            ColliderShape::Capsule {
                radius,
                half_height,
                center,
            } => SceneColliderShapeVerificationState::Capsule {
                radius: *radius,
                half_height: *half_height,
                center: vector_array(*center),
            },
            ColliderShape::Cylinder {
                radius,
                half_height,
                center,
            } => SceneColliderShapeVerificationState::Cylinder {
                radius: *radius,
                half_height: *half_height,
                center: vector_array(*center),
            },
            ColliderShape::HeightField {
                resource_id,
                center,
            } => SceneColliderShapeVerificationState::HeightField {
                resource_id: resource_id.clone(),
                center: vector_array(*center),
            },
            ColliderShape::Mesh {
                resource_id,
                center,
            } => SceneColliderShapeVerificationState::Mesh {
                resource_id: resource_id.clone(),
                center: vector_array(*center),
            },
            ColliderShape::Convex {
                resource_id,
                center,
            } => SceneColliderShapeVerificationState::Convex {
                resource_id: resource_id.clone(),
                center: vector_array(*center),
            },
        }
    }

    /// Snapshot a collider's primary shape, or `None` when it has none.
    pub fn from_collider(collider: &Collider) -> Option<Self> {
        Some(Self::from_shape(&collider.shape()))
    }
}

/// An audio source's verified fields.
///
/// Built from plain values so the snapshot can be constructed even where the authored
/// component type is not available to this crate yet.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SceneAudioSourceVerificationState {
    pub clip_name: String,
    pub volume: f32,
    pub pitch: f32,
    pub loop_: bool,
    pub play_on_awake: bool,
    pub spatial_blend: f32,
}

impl SceneAudioSourceVerificationState {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        clip_name: impl Into<String>,
        volume: f32,
        pitch: f32,
        loop_: bool,
        play_on_awake: bool,
        spatial_blend: f32,
    ) -> Self {
        SceneAudioSourceVerificationState {
            clip_name: clip_name.into(),
            volume,
            pitch,
            loop_,
            play_on_awake,
            spatial_blend,
        }
    }
}

/// A script binding's verified fields.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SceneScriptBindingVerificationState {
    pub script_handle: u64,
    pub script_identifier: Option<String>,
    pub is_enabled: bool,
    pub parameters_json: String,
}

impl SceneScriptBindingVerificationState {
    pub fn new(
        script_handle: u64,
        script_identifier: Option<String>,
        is_enabled: bool,
        parameters_json: impl Into<String>,
    ) -> Self {
        SceneScriptBindingVerificationState {
            script_handle,
            script_identifier,
            is_enabled,
            parameters_json: parameters_json.into(),
        }
    }
}

/// An animation player's verified fields.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SceneAnimationPlayerVerificationState {
    pub clip_name: Option<String>,
    pub speed: f32,
    pub loop_: bool,
    pub is_playing: bool,
    pub time: f64,
}

impl SceneAnimationPlayerVerificationState {
    pub fn new(
        clip_name: Option<String>,
        speed: f32,
        loop_: bool,
        is_playing: bool,
        time: f64,
    ) -> Self {
        SceneAnimationPlayerVerificationState {
            clip_name,
            speed,
            loop_,
            is_playing,
            time,
        }
    }
}

/// An exact authored value checked after all transaction operations run.
///
/// A mismatch fails the transaction and restores the pre-transaction snapshots.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum SceneStateAssertion {
    Parent {
        entity_id: u64,
        parent_id: Option<u64>,
    },
    LocalTransform {
        entity_id: u64,
        matrix: Vec<f32>,
    },
    SceneName {
        entity_id: u64,
        value: String,
    },
    RigidBodyMotionType {
        entity_id: u64,
        value: String,
    },
    RigidBodyMass {
        entity_id: u64,
        value: f32,
    },
    RigidBodyGravityScale {
        entity_id: u64,
        value: f32,
    },
    RigidBodyAllowSleep {
        entity_id: u64,
        value: bool,
    },
    ColliderPrimaryShape {
        entity_id: u64,
        value: SceneColliderShapeVerificationState,
    },
    ColliderTrigger {
        entity_id: u64,
        value: bool,
    },
    ColliderShapeType {
        entity_id: u64,
        value: String,
    },
    ColliderBoxHalfExtents {
        entity_id: u64,
        value: Vec<f32>,
    },
    ColliderSphereRadius {
        entity_id: u64,
        value: f32,
    },
    ColliderCapsuleRadius {
        entity_id: u64,
        value: f32,
    },
    ColliderCapsuleHalfHeight {
        entity_id: u64,
        value: f32,
    },
    ColliderFriction {
        entity_id: u64,
        value: f32,
    },
    ColliderRestitution {
        entity_id: u64,
        value: f32,
    },
    ColliderDensity {
        entity_id: u64,
        value: f32,
    },
    ColliderLayer {
        entity_id: u64,
        value: u16,
    },
    ColliderLayerMask {
        entity_id: u64,
        value: u16,
    },
    ConstraintEnabled {
        entity_id: u64,
        value: bool,
    },
    LightType {
        entity_id: u64,
        value: String,
    },
    LightColor {
        entity_id: u64,
        value: Vec<f32>,
    },
    LightIntensity {
        entity_id: u64,
        value: f32,
    },
    LightRange {
        entity_id: u64,
        value: f32,
    },
    LightSpotInnerAngle {
        entity_id: u64,
        value: f32,
    },
    LightSpotOuterAngle {
        entity_id: u64,
        value: f32,
    },
    LightCastShadows {
        entity_id: u64,
        value: bool,
    },
    MeshColor {
        entity_id: u64,
        value: Vec<f32>,
    },
    MeshVisibility {
        entity_id: u64,
        value: bool,
    },
    Material {
        entity_id: u64,
        base_color: Vec<f32>,
        metallic: f32,
        roughness: f32,
        emissive: Vec<f32>,
    },
    ScriptBindings {
        entity_id: u64,
        value: Vec<SceneScriptBindingVerificationState>,
    },
    CameraTarget {
        entity_id: u64,
        value: Vec<f32>,
    },
    CameraUp {
        entity_id: u64,
        value: Vec<f32>,
    },
    CameraFovRadians {
        entity_id: u64,
        value: f32,
    },
    CameraAspectRatio {
        entity_id: u64,
        value: f32,
    },
    CameraActive {
        entity_id: u64,
        value: bool,
    },
    AudioSource {
        entity_id: u64,
        value: SceneAudioSourceVerificationState,
    },
    AnimationPlayer {
        entity_id: u64,
        value: SceneAnimationPlayerVerificationState,
    },
    AudioListenerVolume {
        entity_id: u64,
        value: f32,
    },
}

impl SceneStateAssertion {
    /// The entity this assertion targets.
    pub fn target_entity_id(&self) -> u64 {
        match self {
            SceneStateAssertion::Parent { entity_id, .. }
            | SceneStateAssertion::LocalTransform { entity_id, .. }
            | SceneStateAssertion::SceneName { entity_id, .. }
            | SceneStateAssertion::RigidBodyMotionType { entity_id, .. }
            | SceneStateAssertion::RigidBodyMass { entity_id, .. }
            | SceneStateAssertion::RigidBodyGravityScale { entity_id, .. }
            | SceneStateAssertion::RigidBodyAllowSleep { entity_id, .. }
            | SceneStateAssertion::ColliderPrimaryShape { entity_id, .. }
            | SceneStateAssertion::ColliderTrigger { entity_id, .. }
            | SceneStateAssertion::ColliderShapeType { entity_id, .. }
            | SceneStateAssertion::ColliderBoxHalfExtents { entity_id, .. }
            | SceneStateAssertion::ColliderSphereRadius { entity_id, .. }
            | SceneStateAssertion::ColliderCapsuleRadius { entity_id, .. }
            | SceneStateAssertion::ColliderCapsuleHalfHeight { entity_id, .. }
            | SceneStateAssertion::ColliderFriction { entity_id, .. }
            | SceneStateAssertion::ColliderRestitution { entity_id, .. }
            | SceneStateAssertion::ColliderDensity { entity_id, .. }
            | SceneStateAssertion::ColliderLayer { entity_id, .. }
            | SceneStateAssertion::ColliderLayerMask { entity_id, .. }
            | SceneStateAssertion::ConstraintEnabled { entity_id, .. }
            | SceneStateAssertion::LightType { entity_id, .. }
            | SceneStateAssertion::LightColor { entity_id, .. }
            | SceneStateAssertion::LightIntensity { entity_id, .. }
            | SceneStateAssertion::LightRange { entity_id, .. }
            | SceneStateAssertion::LightSpotInnerAngle { entity_id, .. }
            | SceneStateAssertion::LightSpotOuterAngle { entity_id, .. }
            | SceneStateAssertion::LightCastShadows { entity_id, .. }
            | SceneStateAssertion::MeshColor { entity_id, .. }
            | SceneStateAssertion::MeshVisibility { entity_id, .. }
            | SceneStateAssertion::Material { entity_id, .. }
            | SceneStateAssertion::ScriptBindings { entity_id, .. }
            | SceneStateAssertion::CameraTarget { entity_id, .. }
            | SceneStateAssertion::CameraUp { entity_id, .. }
            | SceneStateAssertion::CameraFovRadians { entity_id, .. }
            | SceneStateAssertion::CameraAspectRatio { entity_id, .. }
            | SceneStateAssertion::CameraActive { entity_id, .. }
            | SceneStateAssertion::AudioSource { entity_id, .. }
            | SceneStateAssertion::AnimationPlayer { entity_id, .. }
            | SceneStateAssertion::AudioListenerVolume { entity_id, .. } => *entity_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};

    #[test]
    fn a_matrix_flattens_by_column() {
        let mut matrix = Float4x4::from_columns([
            Float4::new(1.0, 2.0, 3.0, 4.0),
            Float4::new(5.0, 6.0, 7.0, 8.0),
            Float4::new(9.0, 10.0, 11.0, 12.0),
            Float4::new(13.0, 14.0, 15.0, 16.0),
        ]);
        let values = matrix_verification_array(&matrix);
        assert_eq!(values, (1..=16).map(|v| v as f32).collect::<Vec<_>>());
        // Ensure the helper did not mutate the matrix.
        matrix.set_column(0, Float4::new(0.0, 0.0, 0.0, 0.0));
        assert_eq!(matrix.columns[0].x, 0.0);
    }

    #[test]
    fn a_box_collider_snapshot_keeps_its_center() {
        let shape = ColliderShape::Box {
            half_extents: Float3::new(1.0, 2.0, 3.0),
            center: Float3::new(4.0, 5.0, 6.0),
        };
        let state = SceneColliderShapeVerificationState::from_shape(&shape);
        assert_eq!(
            state,
            SceneColliderShapeVerificationState::Box {
                half_extents: vec![1.0, 2.0, 3.0],
                center: vec![4.0, 5.0, 6.0],
            }
        );
    }

    #[test]
    fn a_mesh_collider_keeps_its_resource_id() {
        let shape = ColliderShape::Mesh {
            resource_id: Some("hero".to_string()),
            center: Float3::ZERO,
        };
        let state = SceneColliderShapeVerificationState::from_shape(&shape);
        assert_eq!(
            state,
            SceneColliderShapeVerificationState::Mesh {
                resource_id: Some("hero".to_string()),
                center: vec![0.0, 0.0, 0.0],
            }
        );
    }

    #[test]
    fn an_assertion_reports_its_target_entity() {
        let assertion = SceneStateAssertion::SceneName {
            entity_id: 7,
            value: "a".to_string(),
        };
        assert_eq!(assertion.target_entity_id(), 7);
    }

    #[test]
    fn assertions_round_trip() {
        let assertion = SceneStateAssertion::Material {
            entity_id: 3,
            base_color: vec![1.0, 1.0, 1.0, 1.0],
            metallic: 0.5,
            roughness: 0.25,
            emissive: vec![0.0, 0.0, 0.0],
        };
        let json = serde_json::to_string(&assertion).expect("serialize");
        let restored: SceneStateAssertion = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, assertion);
    }
}
