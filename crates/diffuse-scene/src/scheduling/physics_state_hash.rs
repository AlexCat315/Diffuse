//! Deterministic per-frame physics state hash.
//!
//! This is the parity mechanism MIGRATION.md §7.1/§7.2 relies on: the same scene
//! simulated by the Swift and Rust builds must produce the same `u64`. So the
//! combining function is fixed by Swift's constants and **must not be "improved"**
//! — changing the initial value, the multiplier, or the byte order changes every
//! hash and silently invalidates every recorded baseline.

use std::collections::BTreeMap;

use crate::entity_id::EntityID;
use crate::physics::character_controller::CharacterStateFrameResource;
use crate::physics::destruction::DestructionStateFrameResource;
use crate::physics::joints::physics_joint::PhysicsJoint;
use crate::physics::rigid_body::RigidBody;
use crate::physics::soft_bodies::soft_body::SoftBodyStateFrameResource;
use crate::physics::vehicles::vehicle_state::VehicleStateFrameResource;
use crate::runtime_world::RuntimeWorld;

/// Swift's `physicsStateHash(in:)` seed.
pub const PHYSICS_STATE_HASH_SEED: u64 = 1_469_598_103_934_665_603;
/// Swift's FNV-style multiplier.
pub const PHYSICS_STATE_HASH_PRIME: u64 = 1_099_511_628_211;

/// One accumulator, matching Swift's nested `combine` closure.
pub struct PhysicsStateHasher {
    hash: u64,
}

impl PhysicsStateHasher {
    #[inline]
    pub fn new() -> Self {
        PhysicsStateHasher {
            hash: PHYSICS_STATE_HASH_SEED,
        }
    }

    /// Swift folded the value's little-endian bytes one at a time. Iterating the
    /// bytes of the little-endian form reproduces that exactly, including on a
    /// big-endian host.
    #[inline]
    pub fn combine(&mut self, value: u64) {
        for byte in value.to_le_bytes() {
            self.hash ^= u64::from(byte);
            self.hash = self.hash.wrapping_mul(PHYSICS_STATE_HASH_PRIME);
        }
    }

    /// `combineFloat` — the raw bit pattern, so `-0.0` and `0.0` differ and NaN
    /// payloads participate.
    #[inline]
    pub fn combine_float(&mut self, value: f32) {
        self.combine(u64::from(value.to_bits()));
    }

    #[inline]
    pub fn finish(self) -> u64 {
        self.hash
    }
}

impl Default for PhysicsStateHasher {
    fn default() -> Self {
        Self::new()
    }
}

/// Entities sorted by `EntityID::raw_value`, matching Swift's
/// `.sorted { $0.rawValue < $1.rawValue }`.
fn sorted_entities(mut entities: Vec<EntityID>) -> Vec<EntityID> {
    entities.sort_by_key(|entity| entity.raw_value());
    entities
}

fn sorted_values<T>(map: &BTreeMap<EntityID, T>, key: impl Fn(&T) -> EntityID) -> Vec<&T> {
    let mut values: Vec<&T> = map.values().collect();
    values.sort_by_key(|value| key(value).raw_value());
    values
}

/// The full per-frame physics state hash.
pub fn physics_state_hash(world: &RuntimeWorld) -> u64 {
    let mut hasher = PhysicsStateHasher::new();

    // Rigid bodies: identity, world matrix, velocities, sleep flag.
    for entity in sorted_entities(world.entities_with::<RigidBody>()) {
        let (Some(body), Some(transform)) = (
            world.component::<RigidBody>(entity),
            world.world_transform(entity),
        ) else {
            continue;
        };
        hasher.combine(entity.raw_value());
        for column in transform.matrix.columns {
            hasher.combine_float(column.x);
            hasher.combine_float(column.y);
            hasher.combine_float(column.z);
            hasher.combine_float(column.w);
        }
        for value in [
            body.linear_velocity.x,
            body.linear_velocity.y,
            body.linear_velocity.z,
            body.angular_velocity.x,
            body.angular_velocity.y,
            body.angular_velocity.z,
        ] {
            hasher.combine_float(value);
        }
        hasher.combine(u64::from(body.is_sleeping));
    }

    // Joints: identity and enabled flag only.
    for entity in sorted_entities(world.entities_with::<PhysicsJoint>()) {
        let Some(joint) = world.component::<PhysicsJoint>(entity) else {
            continue;
        };
        hasher.combine(entity.raw_value());
        hasher.combine(u64::from(joint.is_enabled));
    }

    // Characters.
    let character_resource = world
        .resource::<CharacterStateFrameResource>()
        .unwrap_or_default();
    for character in sorted_values(&character_resource.states, |state| state.entity) {
        hasher.combine(character.entity.raw_value());
        for value in [
            character.position.x,
            character.position.y,
            character.position.z,
            character.linear_velocity.x,
            character.linear_velocity.y,
            character.linear_velocity.z,
        ] {
            hasher.combine_float(value);
        }
        hasher.combine(u64::from(character.ground_state.raw_value()));
    }

    // Vehicles, including every wheel.
    let vehicle_resource = world
        .resource::<VehicleStateFrameResource>()
        .unwrap_or_default();
    for vehicle in sorted_values(&vehicle_resource.states, |state| state.entity) {
        hasher.combine(vehicle.entity.raw_value());
        hasher.combine_float(vehicle.forward_speed);
        hasher.combine_float(vehicle.engine_rpm);
        hasher.combine(vehicle.current_gear as u64);
        hasher.combine_float(vehicle.clutch_friction);
        for wheel in &vehicle.wheels {
            hasher.combine(wheel.index as u64);
            hasher.combine_float(wheel.angular_velocity);
            hasher.combine_float(wheel.rotation_angle);
            hasher.combine_float(wheel.steer_angle);
            hasher.combine_float(wheel.suspension_length);
            hasher.combine(u64::from(wheel.has_contact));
            hasher.combine(wheel.contact_entity.map_or(0, |entity| entity.raw_value()));
        }
    }

    // Soft bodies.
    let soft_body_resource = world
        .resource::<SoftBodyStateFrameResource>()
        .unwrap_or_default();
    for soft_body in sorted_values(&soft_body_resource.states, |state| state.entity) {
        hasher.combine(soft_body.entity.raw_value());
        hasher.combine(soft_body.positions.len() as u64);
        for position in &soft_body.positions {
            hasher.combine_float(position.x);
            hasher.combine_float(position.y);
            hasher.combine_float(position.z);
        }
        hasher.combine(u64::from(soft_body.is_sleeping));
    }

    // Destruction sources, in full: the hash covers every field a break changes.
    let destruction_resource = world
        .resource::<DestructionStateFrameResource>()
        .unwrap_or_default();
    for source in sorted_values(&destruction_resource.sources, |state| state.source_entity) {
        hasher.combine(source.source_entity.raw_value());
        hasher.combine(u64::from(source.has_fractured));
        hasher.combine(u64::from(source.is_fully_fractured));
        hasher.combine_float(source.accumulated_damage);
        hasher.combine(source.broken_connection_ids.len() as u64);
        for connection_id in &source.broken_connection_ids {
            hasher.combine(u64::from(*connection_id));
        }
        hasher.combine(source.released_fragment_ids.len() as u64);
        for fragment_id in &source.released_fragment_ids {
            hasher.combine(u64::from(*fragment_id));
        }
        hasher.combine(source.retained_fragment_ids.len() as u64);
        for fragment_id in &source.retained_fragment_ids {
            hasher.combine(u64::from(*fragment_id));
        }
        hasher.combine(source.active_fragment_entities.len() as u64);
        // Swift indexed `activeFragmentEntities` and paired each with the
        // same-index `activeFragmentIDs` entry when one exists.
        for (index, entity) in source.active_fragment_entities.iter().enumerate() {
            hasher.combine(entity.raw_value());
            if let Some(fragment_id) = source.active_fragment_ids.get(index) {
                hasher.combine(u64::from(*fragment_id));
            }
        }
    }

    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    #[test]
    fn the_seed_and_prime_are_swifts_constants() {
        // Changing either invalidates every recorded baseline.
        assert_eq!(PHYSICS_STATE_HASH_SEED, 1_469_598_103_934_665_603);
        assert_eq!(PHYSICS_STATE_HASH_PRIME, 1_099_511_628_211);
    }

    #[test]
    fn an_empty_world_hashes_to_the_seed() {
        let world = RuntimeWorld::new(ComponentRegistry::new());
        assert_eq!(physics_state_hash(&world), PHYSICS_STATE_HASH_SEED);
    }

    #[test]
    fn combining_uses_little_endian_bytes() {
        let mut hasher = PhysicsStateHasher::new();
        hasher.combine(1);
        let mut expected = PHYSICS_STATE_HASH_SEED;
        for byte in 1u64.to_le_bytes() {
            expected ^= u64::from(byte);
            expected = expected.wrapping_mul(PHYSICS_STATE_HASH_PRIME);
        }
        assert_eq!(hasher.finish(), expected);
    }

    #[test]
    fn the_hash_changes_when_a_body_moves() {
        use crate::runtime_world::WorldTransform;
        use diffuse_math::simd::simd_compat::{Float4, MATRIX_IDENTITY_FLOAT4X4};

        let mut world = RuntimeWorld::new(ComponentRegistry::new());
        let entity = world.create_entity();
        world.set_component(RigidBody::default(), entity);
        world.set_component(WorldTransform::new(MATRIX_IDENTITY_FLOAT4X4), entity);
        let before = physics_state_hash(&world);

        let mut moved = MATRIX_IDENTITY_FLOAT4X4;
        moved.set_column(3, Float4::new(1.0, 0.0, 0.0, 1.0));
        world.set_component(WorldTransform::new(moved), entity);

        assert_ne!(
            before,
            physics_state_hash(&world),
            "a moved body must change the hash"
        );
    }

    #[test]
    fn the_hash_is_stable_across_repeated_calls() {
        let world = RuntimeWorld::new(ComponentRegistry::new());
        assert_eq!(physics_state_hash(&world), physics_state_hash(&world));
    }
}
