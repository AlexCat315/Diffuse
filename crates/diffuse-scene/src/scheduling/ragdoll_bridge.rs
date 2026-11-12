//! Ragdoll ↔ animation palette bridge.
//!
//! Two directions, run in opposite halves of the frame:
//!
//! - `apply_ragdoll_animation_to_bodies` (`inputAndPrePhysicsScripts`): the animated
//!   palette drives the ragdoll bodies. A bone that is *not* simulating is made
//!   kinematic and given the palette transform as its target, so it still pushes other
//!   bodies around without being integrated.
//! - `write_ragdoll_physics_to_animation` (`physicsWriteback`): simulated bodies are
//!   blended back into the palette so the skinned mesh follows the simulation.
//!
//! Both iterate entities in ascending `EntityID` order, which is what makes the
//! resulting palette reproducible.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, cove_slerp, simd_length,
};

use crate::entity_id::EntityID;
use crate::media::animation::{JointPalette, JointPaletteMap};
use crate::physics::backend::physics_backend_context::PhysicsBodyWriteback;
use crate::physics::ragdoll::{
    Ragdoll, RagdollBoneState, RagdollMode, RagdollState, RagdollStateFrameResource,
};
use crate::physics::rigid_body::{PhysicsKinematicTarget, RigidBody, RigidBodyMotionType};
use crate::runtime_world::{LocalTransform, RuntimeWorld, WorldTransform};

/// Whether a bone should be simulated this frame.
///
/// A bone is simulated only when the ragdoll is enabled, is not in `animated` mode,
/// and the bone itself opted in. `animated` mode disables simulation for the whole
/// ragdoll regardless of per-bone flags.
#[inline]
fn bone_should_simulate(ragdoll: &Ragdoll, is_simulation_enabled: bool) -> bool {
    ragdoll.is_enabled && ragdoll.mode != RagdollMode::Animated && is_simulation_enabled
}

/// The palette-driven pose for one bone, if the palette has the index.
fn desired_world(
    root: &WorldTransform,
    palette: &[Float4x4],
    palette_index: i64,
    body_from_palette: Float4x4,
) -> Option<WorldTransform> {
    let index = usize::try_from(palette_index).ok()?;
    let matrix = palette.get(index)?;
    Some(WorldTransform::new(
        root.matrix * *matrix * body_from_palette,
    ))
}

/// Drive ragdoll bodies from the animation palette.
///
/// Returns the set of bodies that were left simulated, which the schedule stores so
/// the next frame knows which bones it already owns.
pub fn apply_ragdoll_animation_to_bodies(world: &mut RuntimeWorld) -> BTreeSet<EntityID> {
    let palette_map = world.resource::<JointPaletteMap>().unwrap_or_default();
    let previously_simulated = simulated_entities(world);
    let mut next_simulated: BTreeSet<EntityID> = BTreeSet::new();

    let ragdoll_entities = sorted_entities(world.entities_with::<Ragdoll>());
    for entity in ragdoll_entities {
        let (Some(ragdoll), Some(root_world)) = (
            world.component::<Ragdoll>(entity),
            world.world_transform(entity),
        ) else {
            continue;
        };
        let empty_palette: Vec<Float4x4> = Vec::new();
        let palette: &Vec<Float4x4> = palette_map
            .palette(entity)
            .map_or(&empty_palette, |palette| &palette.matrices);

        for bone in &ragdoll.bones {
            if !world.contains(bone.body_entity) {
                continue;
            }
            let Some(mut rigid_body) = world.component::<RigidBody>(bone.body_entity) else {
                continue;
            };

            let should_simulate = bone_should_simulate(&ragdoll, bone.is_simulation_enabled);
            let desired = desired_world(
                &root_world,
                palette,
                bone.palette_index,
                bone.body_from_palette,
            );

            if should_simulate {
                // Only teleport a body that was not already simulated: once the solver
                // owns it, snapping it back to the animation every frame would fight
                // the simulation.
                if !previously_simulated.contains(&bone.body_entity)
                    && let Some(desired) = desired
                {
                    world.apply_physics_writeback(&PhysicsBodyWriteback {
                        world_transform: Some(desired),
                        ..PhysicsBodyWriteback::new(bone.body_entity)
                    });
                }
                rigid_body.motion_type = bone.simulated_motion_type;
                rigid_body.kinematic_target = None;
                rigid_body.is_sleeping = false;
                if desired.is_some() || previously_simulated.contains(&bone.body_entity) {
                    next_simulated.insert(bone.body_entity);
                }
            } else {
                // A non-simulating bone still participates: kinematic motion pushes
                // dynamic bodies without being integrated itself.
                rigid_body.motion_type = RigidBodyMotionType::Kinematic;
                if let Some(desired) = desired {
                    let transform = LocalTransform::new(desired.matrix);
                    rigid_body.kinematic_target = Some(PhysicsKinematicTarget {
                        position: desired.translation(),
                        rotation: transform.rotation().vector,
                    });
                    world.apply_physics_writeback(&PhysicsBodyWriteback {
                        world_transform: Some(desired),
                        ..PhysicsBodyWriteback::new(bone.body_entity)
                    });
                } else {
                    rigid_body.kinematic_target = None;
                }
            }
            world.set_component(rigid_body, bone.body_entity);
        }
    }

    next_simulated
}

/// Blend simulated physics back into the animation palette.
pub fn write_ragdoll_physics_to_animation(world: &mut RuntimeWorld) {
    let mut palette_map = world.resource::<JointPaletteMap>().unwrap_or_default();
    let mut states: BTreeMap<EntityID, RagdollState> = BTreeMap::new();

    let ragdoll_entities = sorted_entities(world.entities_with::<Ragdoll>());
    for entity in ragdoll_entities {
        let (Some(ragdoll), Some(root_world)) = (
            world.component::<Ragdoll>(entity),
            world.world_transform(entity),
        ) else {
            continue;
        };

        let mut matrices = palette_map
            .palette(entity)
            .map(|palette| palette.matrices.clone())
            .unwrap_or_default();
        // Grow the palette to cover every bone index, padding with identity rather
        // than leaving holes a skinned shader would read as garbage.
        let maximum_index = ragdoll
            .bones
            .iter()
            .map(|bone| bone.palette_index)
            .max()
            .unwrap_or(-1);
        if maximum_index >= 0 {
            let required = usize::try_from(maximum_index + 1).unwrap_or(0);
            while matrices.len() < required {
                matrices.push(MATRIX_IDENTITY_FLOAT4X4);
            }
        }

        let mut bone_states: Vec<RagdollBoneState> = Vec::with_capacity(ragdoll.bones.len());
        let inverse_root = root_world.matrix.inverse();

        for bone in &ragdoll.bones {
            let Some(body_world) = world.world_transform(bone.body_entity) else {
                continue;
            };
            let is_simulated = bone_should_simulate(&ragdoll, bone.is_simulation_enabled);
            let weight = match ragdoll.mode {
                RagdollMode::Animated => 0.0,
                RagdollMode::Simulated => {
                    if is_simulated {
                        bone.blend_weight
                    } else {
                        0.0
                    }
                }
                RagdollMode::Blended => {
                    if is_simulated {
                        ragdoll.blend_weight * bone.blend_weight
                    } else {
                        0.0
                    }
                }
            };

            if weight > 0.0
                && let Ok(index) = usize::try_from(bone.palette_index)
                && index < matrices.len()
            {
                let physics_palette =
                    inverse_root * body_world.matrix * bone.body_from_palette.inverse();
                matrices[index] =
                    blend_transform_matrices(matrices[index], physics_palette, weight);
            }

            bone_states.push(RagdollBoneState::new(
                bone.bone_name.clone(),
                bone.palette_index,
                bone.body_entity,
                body_world,
                is_simulated,
            ));
        }

        palette_map
            .palettes
            .insert(entity, JointPalette::new(matrices));
        states.insert(entity, RagdollState::new(entity, ragdoll.mode, bone_states));
    }

    world.set_derived_resource(palette_map);
    world.set_derived_resource(RagdollStateFrameResource::new(states));
}

/// Blend two transforms by `weight`.
///
/// `0` returns the animation exactly, `1` returns the physics exactly, and anything
/// between interpolates translation and scale linearly while slerping rotation. The
/// endpoints are returned **unchanged** rather than blended, so a fully-animated or
/// fully-simulated bone reproduces its source matrix bit-for-bit.
pub fn blend_transform_matrices(animation: Float4x4, physics: Float4x4, weight: f32) -> Float4x4 {
    let t = weight.clamp(0.0, 1.0);
    if t <= 0.0 {
        return animation;
    }
    if t >= 1.0 {
        return physics;
    }

    let animation_transform = LocalTransform::new(animation);
    let physics_transform = LocalTransform::new(physics);
    let translation =
        animation_transform.translation() * (1.0 - t) + physics_transform.translation() * t;
    let rotation = cove_slerp(
        animation_transform.rotation(),
        physics_transform.rotation(),
        t,
    );
    let animation_scale = transform_scale(animation);
    let physics_scale = transform_scale(physics);
    let scale = animation_scale * (1.0 - t) + physics_scale * t;

    let mut result = Float4x4::from_quatf(rotation);
    let column_0 = result.columns[0] * scale.x;
    let column_1 = result.columns[1] * scale.y;
    let column_2 = result.columns[2] * scale.z;
    result.set_column(0, column_0);
    result.set_column(1, column_1);
    result.set_column(2, column_2);
    result.set_column(
        3,
        Float4::new(translation.x, translation.y, translation.z, 1.0),
    );
    result
}

/// The per-axis length of a matrix's basis columns.
pub fn transform_scale(matrix: Float4x4) -> Float3 {
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

fn sorted_entities(mut entities: Vec<EntityID>) -> Vec<EntityID> {
    entities.sort_by_key(|entity| entity.raw_value());
    entities
}

fn simulated_entities(world: &RuntimeWorld) -> BTreeSet<EntityID> {
    world
        .resource::<RagdollSimulatedBodiesResource>()
        .unwrap_or_default()
        .entities
}

/// The set of ragdoll bodies the schedule simulated last frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RagdollSimulatedBodiesResource {
    pub entities: BTreeSet<EntityID>,
}

impl RagdollSimulatedBodiesResource {
    pub fn new(entities: BTreeSet<EntityID>) -> Self {
        RagdollSimulatedBodiesResource { entities }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use crate::physics::ragdoll::RagdollBoneMapping;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    fn world_with_ragdoll(mode: RagdollMode) -> (RuntimeWorld, EntityID, EntityID) {
        let mut world = empty_world();
        let root = world.create_entity();
        let body = world.create_entity();
        world.set_local_transform(LocalTransform::IDENTITY, root);
        world.set_local_transform(LocalTransform::IDENTITY, body);
        world.set_component(RigidBody::default(), body);

        let bones = vec![RagdollBoneMapping::new("spine", 0, body)];
        let ragdoll = Ragdoll::new(mode, 1.0, true, bones);
        world.set_component(ragdoll, root);
        (world, root, body)
    }

    #[test]
    fn blending_at_zero_returns_the_animation_matrix_exactly() {
        let animation = MATRIX_IDENTITY_FLOAT4X4;
        let mut physics = MATRIX_IDENTITY_FLOAT4X4;
        physics.set_column(3, Float4::new(5.0, 0.0, 0.0, 1.0));
        assert_eq!(blend_transform_matrices(animation, physics, 0.0), animation);
    }

    #[test]
    fn blending_at_one_returns_the_physics_matrix_exactly() {
        let animation = MATRIX_IDENTITY_FLOAT4X4;
        let mut physics = MATRIX_IDENTITY_FLOAT4X4;
        physics.set_column(3, Float4::new(5.0, 0.0, 0.0, 1.0));
        assert_eq!(blend_transform_matrices(animation, physics, 1.0), physics);
    }

    #[test]
    fn blending_halfway_interpolates_translation() {
        let animation = MATRIX_IDENTITY_FLOAT4X4;
        let mut physics = MATRIX_IDENTITY_FLOAT4X4;
        physics.set_column(3, Float4::new(4.0, 0.0, 0.0, 1.0));
        let blended = blend_transform_matrices(animation, physics, 0.5);
        assert!((blended.columns[3].x - 2.0).abs() < 1e-5);
    }

    #[test]
    fn animated_mode_never_simulates_a_bone() {
        let (world, root, _body) = world_with_ragdoll(RagdollMode::Animated);
        let ragdoll = world.component::<Ragdoll>(root).expect("ragdoll");
        assert!(
            !bone_should_simulate(&ragdoll, true),
            "animated mode must disable simulation"
        );
    }

    #[test]
    fn a_non_simulating_bone_becomes_kinematic() {
        let (mut world, _root, body) = world_with_ragdoll(RagdollMode::Animated);
        let _ = apply_ragdoll_animation_to_bodies(&mut world);
        let rigid_body = world.component::<RigidBody>(body).expect("body");
        assert_eq!(rigid_body.motion_type, RigidBodyMotionType::Kinematic);
    }

    #[test]
    fn the_palette_grows_to_cover_every_bone_index() {
        let (mut world, root, body) = world_with_ragdoll(RagdollMode::Simulated);
        let mut ragdoll = world.component::<Ragdoll>(root).expect("ragdoll");
        ragdoll.bones.clear();
        ragdoll.bones.push(RagdollBoneMapping::new("a", 0, body));
        ragdoll.bones.push(RagdollBoneMapping::new("b", 3, body));
        world.set_component(ragdoll, root);

        write_ragdoll_physics_to_animation(&mut world);
        let palette_map = world.resource::<JointPaletteMap>().expect("palette map");
        let palette = palette_map.palette(root).expect("palette");
        assert_eq!(palette.matrices.len(), 4, "palette must cover index 3");
    }

    #[test]
    fn a_ragdoll_state_is_written_for_each_ragdoll() {
        let (mut world, root, _body) = world_with_ragdoll(RagdollMode::Simulated);
        write_ragdoll_physics_to_animation(&mut world);
        let states = world
            .resource::<RagdollStateFrameResource>()
            .expect("state frame");
        assert!(states.states.contains_key(&root));
        assert_eq!(states.states[&root].bones.len(), 1);
    }
}
