//! `Core/Builtins.swift` — the registry every new world starts from.
//!
//! Module codecs are added locally afterwards. Registration order is the Swift
//! order because it decides payload order and the editor's add-menu order.
//!
//! Swift's second `ComponentSchema` initializer adapts a value codec
//! (`(Component) -> [String: Any]` plus the inverse) into the world-closure form.
//! Rust fn pointers cannot capture the codec functions, so [`codec_schema!`]
//! expands the adapter as three local `fn` items per component; the generated
//! bodies are exactly the Swift adapters, including `decode([:])` as the default.

use std::collections::BTreeMap;

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{decode_json_value, json_to_int};
use crate::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentEncodePurpose,
    ComponentRegistry, ComponentSchema,
};
use crate::components::core::value::ComponentValue;
use crate::components::editing::motion_quality::merge_rigid_body;
use crate::components::inspection::inspection::ComponentInspection;
use crate::entity_id::{EntityID, RuntimeComponent};
use crate::media::animation::{
    AnimationGraph, AnimationGraphPlayer, AnimationMotion, AnimationPlayer, AnimationState,
    AnimationStateMachine,
};
use crate::media::audio::{AudioListener, AudioSource};
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::Collider;
use crate::physics::destruction::{
    Destructible, DestructionRuntimeSourceState, DestructionRuntimeStateResource,
};
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::ragdoll::Ragdoll;
use crate::physics::rigid_body::RigidBody;
use crate::physics::soft_bodies::cloth::Cloth;
use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::rendering::render_extraction::{
    CameraComponent, LightComponent, RenderMaterialComponent, RenderMeshComponent,
};
use crate::runtime_world::{LocalTransform, RuntimeWorld};
use crate::scene_bootstrap::AssetReferenceComponent;

/// A schema backed by a value codec, with the codec's own `decode([:])` default.
macro_rules! codec_schema {
    ($component:ty, $type_id:expr, $display_name:expr, $category:expr,
     $serialize:path, $deserialize:path, $configure:expr) => {
        codec_schema!(
            @build $component, $type_id, $display_name, $category, $serialize, $deserialize,
            |entity: EntityID, world: &mut RuntimeWorld| {
                let _ = world.set_component($deserialize(&BTreeMap::new()), entity);
            },
            $configure
        )
    };
    ($component:ty, $type_id:expr, $display_name:expr, $category:expr,
     $serialize:path, $deserialize:path, default: $make_default:expr, $configure:expr) => {
        codec_schema!(
            @build $component, $type_id, $display_name, $category, $serialize, $deserialize,
            $make_default, $configure
        )
    };
    (@build $component:ty, $type_id:expr, $display_name:expr, $category:expr,
     $serialize:path, $deserialize:path, $make_default:expr, $configure:expr) => {{
        fn encode(
            world: &RuntimeWorld,
            entity: EntityID,
            _context: &mut ComponentEncodeContext,
        ) -> Option<ComponentValue> {
            world
                .component::<$component>(entity)
                .map(|component| ComponentValue::Object($serialize(&component)))
        }
        fn decode(
            value: &ComponentValue,
            entity: EntityID,
            _context: &mut ComponentDecodeContext,
            world: &mut RuntimeWorld,
        ) {
            let Some(document) = value.object_value() else {
                return;
            };
            let _ = world.set_component($deserialize(document), entity);
        }
        let mut schema = ComponentSchema::for_component::<$component>(
            $type_id,
            $display_name,
            $category,
            encode,
            decode,
            $make_default,
        );
        let configure: fn(&mut ComponentSchema) = $configure;
        configure(&mut schema);
        schema
    }};
}

/// A schema whose encode reads the authored destruction snapshot first.
macro_rules! authored_schema {
    ($component:ty, $type_id:expr, $display_name:expr, $category:expr,
     $snapshot:expr, $serialize:path, $deserialize:path, $configure:expr) => {{
        fn encode(
            world: &RuntimeWorld,
            entity: EntityID,
            context: &mut ComponentEncodeContext,
        ) -> Option<ComponentValue> {
            BuiltinComponentCodecs::authored_component::<$component>(
                world, entity, context, $snapshot,
            )
            .map(|component| ComponentValue::Object($serialize(&component)))
        }
        fn decode(
            value: &ComponentValue,
            entity: EntityID,
            _context: &mut ComponentDecodeContext,
            world: &mut RuntimeWorld,
        ) {
            let Some(document) = value.object_value() else {
                return;
            };
            let _ = world.set_component($deserialize(document), entity);
        }
        fn make_default(entity: EntityID, world: &mut RuntimeWorld) {
            let _ = world.set_component($deserialize(&BTreeMap::new()), entity);
        }
        let mut schema = ComponentSchema::for_component::<$component>(
            $type_id,
            $display_name,
            $category,
            encode,
            decode,
            make_default,
        );
        let configure: fn(&mut ComponentSchema) = $configure;
        configure(&mut schema);
        schema
    }};
}

/// Swift `mergeParticleEmitter`: re-applying a lone `settings` object keeps the
/// emitter's live runtime state when the seed is unchanged.
fn merge_particle_emitter(
    previous: &ComponentValue,
    changes: &ComponentValue,
) -> Result<ComponentValue, crate::components::editing::ComponentEditError> {
    let merged = previous.merging(changes)?;
    let Some(document) = merged.object_value() else {
        return Ok(merged);
    };
    let Some(fields) = changes.object_value() else {
        return Ok(merged);
    };
    if fields.get("settings").is_none() || fields.get("moduleStack").is_some() {
        return Ok(merged);
    }
    let Some(settings) = decode_json_value::<ParticleEmitterSettings>(document.get("settings"))
    else {
        return Ok(merged);
    };
    let Some(original) = previous.object_value() else {
        return Ok(merged);
    };
    let mut emitter = BuiltinComponentCodecs::deserialize_particle_emitter(original);
    emitter.settings = settings;
    emitter.settings.normalize();
    Ok(ComponentValue::Object(
        BuiltinComponentCodecs::serialize_particle_emitter(&emitter),
    ))
}

/// Swift `applyEdit` for the particle emitter: an unchanged seed preserves the
/// running simulation instead of restarting it.
fn apply_particle_emitter_edit(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let Some(document) = value.object_value() else {
        return;
    };
    let mut edited = BuiltinComponentCodecs::deserialize_particle_emitter(document);
    if let Some(previous) = world.component::<ParticleEmitter>(entity)
        && previous.settings.emission.seed == edited.settings.emission.seed
    {
        edited.runtime = previous.runtime;
    }
    let _ = world.set_component(edited, entity);
}

impl ComponentRegistry {
    /// Creates the built-in set for a new world. Module codecs are added locally.
    pub fn built_in() -> ComponentRegistry {
        let mut registry = ComponentRegistry::new();
        registry.register(codec_schema!(
            LocalTransform,
            "localTransform",
            "Transform",
            ComponentCategory::Rendering,
            BuiltinComponentCodecs::serialize_local_transform,
            BuiltinComponentCodecs::deserialize_local_transform,
            default: |entity: EntityID, world: &mut RuntimeWorld| {
                let _ = world.set_local_transform(LocalTransform::IDENTITY, entity);
            },
            |schema: &mut ComponentSchema| {
                schema.is_structural = true;
                schema.is_user_addable = false;
            }
        ));
        registry.register(authored_schema!(
            RigidBody,
            "rigidbody",
            "Rigid Body",
            ComponentCategory::Physics,
            |source: &DestructionRuntimeSourceState| source.authored_rigid_body.clone(),
            BuiltinComponentCodecs::serialize_rigid_body,
            BuiltinComponentCodecs::deserialize_rigid_body,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::rigid_body();
                schema.merge = merge_rigid_body;
            }
        ));
        registry.register(authored_schema!(
            Collider,
            "collider",
            "Collider",
            ComponentCategory::Physics,
            |source: &DestructionRuntimeSourceState| source.authored_collider.clone(),
            BuiltinComponentCodecs::serialize_collider,
            BuiltinComponentCodecs::deserialize_collider,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
            }
        ));
        registry.register(codec_schema!(
            CharacterController,
            "characterController",
            "Character Controller",
            ComponentCategory::Gameplay,
            BuiltinComponentCodecs::serialize_character_controller,
            BuiltinComponentCodecs::deserialize_character_controller,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::character_controller();
            }
        ));
        registry.register(codec_schema!(
            Vehicle,
            "vehicle",
            "Vehicle",
            ComponentCategory::Gameplay,
            BuiltinComponentCodecs::serialize_vehicle,
            BuiltinComponentCodecs::deserialize_vehicle,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
            }
        ));
        registry.register(codec_schema!(
            SoftBody,
            "softBody",
            "Soft Body",
            ComponentCategory::Physics,
            BuiltinComponentCodecs::serialize_soft_body,
            BuiltinComponentCodecs::deserialize_soft_body,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::soft_body();
            }
        ));
        registry.register(codec_schema!(
            Cloth,
            "cloth",
            "Cloth",
            ComponentCategory::Physics,
            BuiltinComponentCodecs::serialize_cloth,
            BuiltinComponentCodecs::deserialize_cloth,
            default: |entity: EntityID, world: &mut RuntimeWorld| {
                let _ = world.set_component(Cloth::fixed_top_edge(16, 16, 0.2), entity);
            },
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.incompatible_with = vec!["softBodyMesh".to_string()];
                schema.inspection = ComponentInspection::cloth();
                schema.normalize_changes = Some(BuiltinComponentCodecs::normalize_cloth_changes);
            }
        ));
        registry.register(codec_schema!(
            SoftBodyMesh,
            "softBodyMesh",
            "Soft Body Mesh",
            ComponentCategory::Physics,
            BuiltinComponentCodecs::serialize_soft_body_mesh,
            BuiltinComponentCodecs::deserialize_soft_body_mesh,
            default: |entity: EntityID, world: &mut RuntimeWorld| {
                let resource_id = world
                    .component::<AssetReferenceComponent>(entity)
                    .map(|reference| format!("meshIndex:{}", reference.mesh_index));
                let _ = world.set_component(
                    SoftBodyMesh {
                        resource_id,
                        ..SoftBodyMesh::default()
                    },
                    entity,
                );
            },
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.incompatible_with = vec!["cloth".to_string()];
                schema.inspection = ComponentInspection::soft_body_mesh();
                schema.normalize_changes =
                    Some(BuiltinComponentCodecs::normalize_soft_body_mesh_changes);
            }
        ));
        registry.register(codec_schema!(
            Destructible,
            "destructible",
            "Destructible",
            ComponentCategory::Physics,
            BuiltinComponentCodecs::serialize_destructible,
            BuiltinComponentCodecs::deserialize_destructible,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
            }
        ));
        registry.register(authored_schema!(
            RenderMeshComponent,
            "renderMesh",
            "Render Mesh",
            ComponentCategory::Rendering,
            |source: &DestructionRuntimeSourceState| source.authored_render_mesh.clone(),
            BuiltinComponentCodecs::serialize_render_mesh,
            BuiltinComponentCodecs::deserialize_render_mesh,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::render_mesh();
            }
        ));
        registry.register(codec_schema!(
            CameraComponent,
            "camera",
            "Camera",
            ComponentCategory::Rendering,
            BuiltinComponentCodecs::serialize_camera,
            BuiltinComponentCodecs::deserialize_camera,
            default: |entity: EntityID, world: &mut RuntimeWorld| {
                let _ = world.set_component(
                    CameraComponent {
                        is_active: false,
                        ..CameraComponent::default()
                    },
                    entity,
                );
            },
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::camera();
                schema.after_duplicate = |entity: EntityID, world: &mut RuntimeWorld| {
                    let _ = world
                        .update_component::<CameraComponent>(entity, |camera| camera.is_active = false);
                };
            }
        ));
        registry.register(codec_schema!(
            LightComponent,
            "light",
            "Light",
            ComponentCategory::Rendering,
            BuiltinComponentCodecs::serialize_light,
            BuiltinComponentCodecs::deserialize_light,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::light();
            }
        ));
        registry.register(codec_schema!(
            AudioSource,
            "audioSource",
            "Audio Source",
            ComponentCategory::Audio,
            BuiltinComponentCodecs::serialize_audio_source,
            BuiltinComponentCodecs::deserialize_audio_source,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::audio_source();
            }
        ));
        registry.register(codec_schema!(
            AudioListener,
            "audioListener",
            "Audio Listener",
            ComponentCategory::Audio,
            BuiltinComponentCodecs::serialize_audio_listener,
            BuiltinComponentCodecs::deserialize_audio_listener,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.inspection = ComponentInspection::audio_listener();
            }
        ));
        registry.register(codec_schema!(
            RenderMaterialComponent,
            "renderMaterial",
            "Render Material",
            ComponentCategory::Rendering,
            BuiltinComponentCodecs::serialize_render_material,
            BuiltinComponentCodecs::deserialize_render_material,
            |schema: &mut ComponentSchema| {
                schema.inspection = ComponentInspection::render_material();
            }
        ));
        registry.register(codec_schema!(
            AssetReferenceComponent,
            "assetReference",
            "Asset Reference",
            ComponentCategory::Assets,
            BuiltinComponentCodecs::serialize_asset_reference,
            BuiltinComponentCodecs::deserialize_asset_reference,
            |schema: &mut ComponentSchema| {
                schema.is_user_addable = false;
                schema.inspection.is_read_only = true;
            }
        ));
        registry.register(codec_schema!(
            AnimationPlayer,
            "animationPlayer",
            "Animation Player",
            ComponentCategory::Animation,
            BuiltinComponentCodecs::serialize_animation_player,
            BuiltinComponentCodecs::deserialize_animation_player,
            |schema: &mut ComponentSchema| {
                schema.inspection = ComponentInspection::animation_player();
                schema.merge = BuiltinComponentCodecs::merge_animation_player;
            }
        ));
        registry.register(codec_schema!(
            AnimationGraphPlayer,
            "animationGraphPlayer",
            "Animation Graph",
            ComponentCategory::Animation,
            BuiltinComponentCodecs::serialize_animation_graph_player,
            BuiltinComponentCodecs::deserialize_animation_graph_player,
            default: |entity: EntityID, world: &mut RuntimeWorld| {
                let graph = AnimationGraph::new(
                    Vec::new(),
                    AnimationStateMachine::new(
                        "Default",
                        vec![AnimationState::new(
                            "Default",
                            AnimationMotion::Clip(None),
                            1.0,
                            true,
                        )],
                        Vec::new(),
                    ),
                );
                let _ = world.set_component(AnimationGraphPlayer::from_graph(graph), entity);
            },
            |_schema: &mut ComponentSchema| ()
        ));
        registry.register(codec_schema!(
            ParticleEmitter,
            "particleEmitter",
            "Particle Emitter",
            ComponentCategory::Rendering,
            BuiltinComponentCodecs::serialize_particle_emitter,
            BuiltinComponentCodecs::deserialize_particle_emitter,
            |schema: &mut ComponentSchema| {
                schema.requires = vec!["localTransform".to_string()];
                schema.merge = merge_particle_emitter;
                schema.apply_edit = apply_particle_emitter_edit;
            }
        ));
        registry.register({
            fn encode(
                world: &RuntimeWorld,
                entity: EntityID,
                context: &mut ComponentEncodeContext,
            ) -> Option<ComponentValue> {
                let value = world.component::<Constraint>(entity)?;
                let entity_a = *context.entity_index_map.get(&value.entity_a)?;
                let entity_b = *context.entity_index_map.get(&value.entity_b)?;
                Some(ComponentValue::Object(
                    BuiltinComponentCodecs::serialize_constraint(&value, entity_a, entity_b),
                ))
            }
            fn decode(
                value: &ComponentValue,
                entity: EntityID,
                context: &mut ComponentDecodeContext,
                world: &mut RuntimeWorld,
            ) {
                let Some(document) = value.object_value() else {
                    return;
                };
                let (Some(entity_a), Some(entity_b)) = (
                    json_to_int(document.get("entityA")),
                    json_to_int(document.get("entityB")),
                ) else {
                    return;
                };
                let (Some(entity_a), Some(entity_b)) = (
                    context.entity_map.get(&entity_a),
                    context.entity_map.get(&entity_b),
                ) else {
                    return;
                };
                let _ = world.set_component(
                    BuiltinComponentCodecs::deserialize_constraint(document, *entity_a, *entity_b),
                    entity,
                );
            }
            fn make_default(entity: EntityID, world: &mut RuntimeWorld) {
                // Endpoints are required, so `constraint` has no add-menu default.
                let _ = (entity, world);
            }
            let mut schema = ComponentSchema::for_component::<Constraint>(
                "constraint",
                "Constraint",
                ComponentCategory::Physics,
                encode,
                decode,
                make_default,
            );
            schema.runtime_type_name = "Constraint".to_string();
            schema.is_user_addable = false;
            schema.inspection = ComponentInspection::constraint();
            schema
        });
        registry.register({
            fn encode(
                world: &RuntimeWorld,
                entity: EntityID,
                context: &mut ComponentEncodeContext,
            ) -> Option<ComponentValue> {
                world.component::<Ragdoll>(entity).map(|ragdoll| {
                    ComponentValue::Object(BuiltinComponentCodecs::serialize_ragdoll(
                        &ragdoll,
                        &context.entity_index_map,
                    ))
                })
            }
            fn decode(
                value: &ComponentValue,
                entity: EntityID,
                context: &mut ComponentDecodeContext,
                world: &mut RuntimeWorld,
            ) {
                let Some(document) = value.object_value() else {
                    return;
                };
                let _ = world.set_component(
                    BuiltinComponentCodecs::deserialize_ragdoll(document, &context.entity_map),
                    entity,
                );
            }
            fn make_default(entity: EntityID, world: &mut RuntimeWorld) {
                let _ = world.set_component(Ragdoll::default(), entity);
            }
            ComponentSchema::for_component::<Ragdoll>(
                "ragdoll",
                "Ragdoll",
                ComponentCategory::Physics,
                encode,
                decode,
                make_default,
            )
        });
        registry
    }
}

impl BuiltinComponentCodecs {
    /// Swift `authoredComponent(_:for:in:context:snapshot:)`.
    ///
    /// Authored serialization prefers the destruction source's pre-fracture
    /// snapshot over the live component, so re-saving a fractured scene restores
    /// the authored body instead of the current fragment state.
    pub(crate) fn authored_component<C: RuntimeComponent>(
        world: &RuntimeWorld,
        entity: EntityID,
        context: &ComponentEncodeContext,
        snapshot: fn(&DestructionRuntimeSourceState) -> Option<C>,
    ) -> Option<C> {
        if context.purpose == ComponentEncodePurpose::Authored
            && let Some(source) = world
                .resource::<DestructionRuntimeStateResource>()
                .and_then(|runtime| runtime.sources.get(&entity).cloned())
            && source.has_authored_source_snapshot
        {
            return snapshot(&source);
        }
        world.component::<C>(entity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_builtin_registry_keeps_the_swift_registration_order() {
        let registry = ComponentRegistry::built_in();
        let type_ids: Vec<&str> = registry
            .schemas
            .iter()
            .map(|schema| schema.type_id.as_str())
            .collect();
        assert_eq!(
            type_ids,
            vec![
                "localTransform",
                "rigidbody",
                "collider",
                "characterController",
                "vehicle",
                "softBody",
                "cloth",
                "softBodyMesh",
                "destructible",
                "renderMesh",
                "camera",
                "light",
                "audioSource",
                "audioListener",
                "renderMaterial",
                "assetReference",
                "animationPlayer",
                "animationGraphPlayer",
                "particleEmitter",
                "constraint",
                "ragdoll",
            ]
        );
    }

    #[test]
    fn structural_and_authoring_flags_match_the_swift_configure_closures() {
        let registry = ComponentRegistry::built_in();
        let transform = registry.get("localTransform").expect("localTransform");
        assert!(transform.is_structural);
        assert!(!transform.is_user_addable);

        let constraint = registry.get("constraint").expect("constraint");
        assert!(!constraint.is_user_addable);
        assert_eq!(constraint.runtime_type_name, "Constraint");

        let asset_reference = registry.get("assetReference").expect("assetReference");
        assert!(!asset_reference.is_user_addable);
        assert!(asset_reference.inspection.is_read_only);

        let rigid_body = registry.get("rigidbody").expect("rigidbody");
        assert_eq!(rigid_body.requires, vec!["localTransform".to_string()]);
    }

    #[test]
    fn the_builtin_registry_resolves_every_requirement() {
        let registry = ComponentRegistry::built_in();
        assert!(registry.validate_requirements().is_ok());
    }
}
