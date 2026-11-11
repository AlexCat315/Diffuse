//! Scene naming/reference components and the editor preview bootstrap.
//!
//! Ported from `Engine/Sources/SceneRuntime/SceneBootstrap.swift`.
//!
//! The component types and the three preview matrix helpers are the closed prefix:
//! they have no forward dependency. `bootstrap_editor_preview_scene` is a
//! `SceneRuntime` extension, so it lands with `scene_runtime.rs`; it also needs
//! `ParticleEmitter`, which is a separate module.

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};

use crate::runtime_world::LocalTransform;

use crate::entity_id::{EntityID, RuntimeComponent};

/// `SceneNameComponent` — the display name shown in the hierarchy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneNameComponent {
    pub value: String,
}

impl SceneNameComponent {
    pub fn new(value: impl Into<String>) -> Self {
        SceneNameComponent {
            value: value.into(),
        }
    }
}

impl RuntimeComponent for SceneNameComponent {}

/// `SceneKindComponent` — the authored category label ("Camera", "Group", ...).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneKindComponent {
    pub value: String,
}

impl SceneKindComponent {
    pub fn new(value: impl Into<String>) -> Self {
        SceneKindComponent {
            value: value.into(),
        }
    }
}

impl RuntimeComponent for SceneKindComponent {}

/// `AssetReferenceComponent` — the imported-asset provenance of an entity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssetReferenceComponent {
    pub asset_id: String,
    pub name: String,
    pub relative_path: String,
    pub absolute_path: String,
    pub kind: String,
    pub mesh_index: i64,
}

impl AssetReferenceComponent {
    pub fn new(
        asset_id: impl Into<String>,
        name: impl Into<String>,
        relative_path: impl Into<String>,
        absolute_path: impl Into<String>,
        kind: impl Into<String>,
        mesh_index: i64,
    ) -> Self {
        AssetReferenceComponent {
            asset_id: asset_id.into(),
            name: name.into(),
            relative_path: relative_path.into(),
            absolute_path: absolute_path.into(),
            kind: kind.into(),
            mesh_index,
        }
    }
}

impl RuntimeComponent for AssetReferenceComponent {}

/// `SceneBootstrapDefaultsResource` — the editor's initial selection and expansion.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SceneBootstrapDefaultsResource {
    pub default_selection: Option<EntityID>,
    pub default_expanded: Vec<EntityID>,
}

impl SceneBootstrapDefaultsResource {
    pub fn new(default_selection: Option<EntityID>, default_expanded: Vec<EntityID>) -> Self {
        SceneBootstrapDefaultsResource {
            default_selection,
            default_expanded,
        }
    }
}

/// `previewTranslationMatrix(_:)`.
pub fn preview_translation_matrix(translation: Float3) -> Float4x4 {
    Float4x4::from_rows(&[
        Float4::new(1.0, 0.0, 0.0, translation.x),
        Float4::new(0.0, 1.0, 0.0, translation.y),
        Float4::new(0.0, 0.0, 1.0, translation.z),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

/// `previewScaleMatrix(_:)`.
pub fn preview_scale_matrix(scale: Float3) -> Float4x4 {
    Float4x4::from_rows(&[
        Float4::new(scale.x, 0.0, 0.0, 0.0),
        Float4::new(0.0, scale.y, 0.0, 0.0),
        Float4::new(0.0, 0.0, scale.z, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

/// `previewTranslationScaleMatrix(translation:scale:)` — translation times scale,
/// in that order, so the scale applies first.
pub fn preview_translation_scale_matrix(translation: Float3, scale: Float3) -> Float4x4 {
    preview_translation_matrix(translation) * preview_scale_matrix(scale)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_translation_writes_column_three() {
        let matrix = preview_translation_matrix(Float3::new(4.0, 6.0, 2.0));
        assert_eq!(matrix.columns[3], Float4::new(4.0, 6.0, 2.0, 1.0));
        assert_eq!(matrix.columns[0], Float4::new(1.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn preview_scale_writes_diagonal() {
        let matrix = preview_scale_matrix(Float3::new(8.0, 0.5, 8.0));
        assert_eq!(matrix.columns[0], Float4::new(8.0, 0.0, 0.0, 0.0));
        assert_eq!(matrix.columns[1], Float4::new(0.0, 0.5, 0.0, 0.0));
        assert_eq!(matrix.columns[2], Float4::new(0.0, 0.0, 8.0, 0.0));
        assert_eq!(matrix.columns[3], Float4::new(0.0, 0.0, 0.0, 1.0));
    }

    #[test]
    fn preview_translation_scale_is_translation_times_scale() {
        let translation = Float3::new(0.0, -1.0, 0.0);
        let scale = Float3::new(8.0, 0.5, 8.0);
        let combined = preview_translation_scale_matrix(translation, scale);
        assert_eq!(
            combined,
            preview_translation_matrix(translation) * preview_scale_matrix(scale)
        );
        // Scale lands on the diagonal, translation on column 3 — the translation is
        // not scaled.
        assert_eq!(combined.columns[0], Float4::new(8.0, 0.0, 0.0, 0.0));
        assert_eq!(combined.columns[3], Float4::new(0.0, -1.0, 0.0, 1.0));
    }

    #[test]
    fn bootstrap_defaults_have_no_selection() {
        let defaults = SceneBootstrapDefaultsResource::default();
        assert_eq!(defaults.default_selection, None);
        assert!(defaults.default_expanded.is_empty());
    }
}

/// `SceneRuntime.bootstrapEditorPreviewScene()` — the editor's starter scene.
///
/// Only an empty scene is seeded. Every value mirrors Swift's preview scene so
/// the editor shows the same camera, light, hero, socket, sparks, ground and
/// follow constraint on first launch.
impl crate::scene_runtime::SceneRuntime {
    pub fn bootstrap_editor_preview_scene(&mut self) {
        use crate::particles::emitter::particle_emitter::ParticleEmitter;
        use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
        use crate::physics::collider::{Collider, ColliderShape};
        use crate::physics::joints::physics_joint::PhysicsJoint;
        use crate::physics::joints::physics_joint_configuration::PhysicsJointKind;
        use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
        use crate::rendering::render_extraction::{
            CameraComponent, LightComponent, RenderMeshComponent,
        };

        if self.snapshot().entity_count != 0 {
            return;
        }

        let camera = self.make_preview_entity(
            "Main Camera",
            "Camera",
            preview_translation_matrix(Float3::new(0.0, 2.4, 7.5)),
        );
        let _ = self.set_component(
            CameraComponent {
                target: Float3::new(0.0, 1.0, 0.0),
                is_active: true,
                ..Default::default()
            },
            camera,
        );

        let key_light = self.make_preview_entity(
            "Key Light",
            "Directional Light",
            preview_translation_matrix(Float3::new(4.0, 6.0, 2.0)),
        );
        let _ = self.set_component(
            LightComponent {
                color: Float3::new(1.0, 0.95, 0.86),
                intensity: 3.0,
                ..Default::default()
            },
            key_light,
        );

        let gameplay = self.make_preview_entity("Gameplay", "Group", MATRIX_IDENTITY_FLOAT4X4);

        let hero = self.make_preview_entity(
            "Hero",
            "Static Mesh",
            preview_translation_matrix(Float3::new(0.0, 1.0, 0.0)),
        );
        let _ = self.set_component(
            RenderMeshComponent::new(1, true, Float3::ONE, None, Vec::new()),
            hero,
        );
        let _ = self.set_component(
            RigidBody::new(RigidBodyOptions {
                motion_type: RigidBodyMotionType::Dynamic,
                mass: 80.0,
                gravity_scale: 1.0,
                allow_sleep: true,
                ..Default::default()
            }),
            hero,
        );
        let _ = self.set_component(
            Collider::with_shape(ColliderShape::Capsule {
                radius: 0.35,
                half_height: 0.9,
                center: Float3::new(0.0, 0.9, 0.0),
            }),
            hero,
        );

        let socket = self.make_preview_entity(
            "Sword Socket",
            "Locator",
            preview_translation_matrix(Float3::new(0.55, 1.2, 0.15)),
        );

        let sparks = self.make_preview_entity(
            "Sparks",
            "Particle Emitter",
            preview_translation_matrix(Float3::new(0.0, 2.2, 0.0)),
        );
        let mut settings = ParticleEmitterSettings::default();
        settings.emission.emission_rate = 60.0;
        settings.emission.max_particles = 512;
        settings.appearance.lifetime = 1.6;
        settings.appearance.lifetime_randomness = 0.4;
        settings.shape.spawn_radius = 0.15;
        settings.velocity.start_velocity = Float3::new(0.0, 1.6, 0.0);
        settings.velocity.velocity_randomness = Float3::new(0.8, 0.4, 0.8);
        settings.forces.gravity = Float3::new(0.0, -1.2, 0.0);
        settings.appearance.start_size = 0.18;
        settings.appearance.end_size = 0.0;
        settings.appearance.start_color = Float4::new(1.0, 0.7, 0.25, 1.0);
        settings.appearance.end_color = Float4::new(0.9, 0.1, 0.0, 0.0);
        let _ = self.set_component(ParticleEmitter::new(settings), sparks);

        let ground = self.make_preview_entity(
            "Ground",
            "Static Mesh",
            preview_translation_scale_matrix(
                Float3::new(0.0, -1.0, 0.0),
                Float3::new(8.0, 0.5, 8.0),
            ),
        );
        let _ = self.set_component(
            RenderMeshComponent::new(0, true, Float3::ONE, None, Vec::new()),
            ground,
        );
        let _ = self.set_component(
            RigidBody::new(RigidBodyOptions {
                motion_type: RigidBodyMotionType::Static,
                mass: 0.0,
                gravity_scale: 0.0,
                allow_sleep: false,
                ..Default::default()
            }),
            ground,
        );
        let _ = self.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::new(8.0, 0.5, 8.0),
                center: Float3::new(0.0, -0.5, 0.0),
            }),
            ground,
        );

        let constraint =
            self.make_preview_entity("Hero Follow", "Constraint", MATRIX_IDENTITY_FLOAT4X4);
        let _ = self.set_component(
            PhysicsJoint::from_kind(
                PhysicsJointKind::Distance,
                hero,
                camera,
                Float3::ZERO,
                Float3::ZERO,
                Float3::new(0.0, 1.0, 0.0),
                Float3::new(0.0, 1.0, 0.0),
                2.5,
                6.0,
                true,
                f32::MAX,
                f32::MAX,
            ),
            constraint,
        );

        let _ = self.set_parent(Some(gameplay), hero);
        let _ = self.set_parent(Some(hero), socket);
        let _ = self.set_parent(Some(gameplay), ground);
        let _ = self.set_parent(Some(gameplay), constraint);
        self.propagate_transforms();
        self.set_resource(SceneBootstrapDefaultsResource::new(
            Some(hero),
            vec![gameplay, hero],
        ));
    }

    fn make_preview_entity(&mut self, name: &str, kind: &str, matrix: Float4x4) -> EntityID {
        let entity = self.create_entity();
        let _ = self.set_component(SceneNameComponent::new(name), entity);
        let _ = self.set_component(SceneKindComponent::new(kind), entity);
        let _ = self.set_local_transform(LocalTransform::new(matrix), entity);
        entity
    }
}
