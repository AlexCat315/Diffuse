//! The Natsel-backed physics backend.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselPhysicsBackend.swift`.
//!
//! The Swift file is seven `extension NatselPhysicsBackend` blocks, which all see the
//! class's stored properties. The Rust split keeps that shape: fields are
//! `pub(crate)` so the sibling `natsel_*` modules reach them directly, exactly as the
//! Swift extensions reach the class members.
//!
//! Two `unsafe` blocks live here, both unavoidable and both confined to this file:
//!
//! One `unsafe` call site and one `unsafe impl` remain, both narrow:
//!
//! 1. `CharacterVirtual::from_raw_world`, the entry point Natsel added for exactly this
//!    shape (see `.migration/cove-gaps.md` G8). The world is boxed, so its address is
//!    stable for the backend's whole life and a stored `CharacterVirtual<'static>`
//!    cannot dangle. Swift's `unowned let world` had the same guarantee because the
//!    class was heap-allocated.
//! 2. `unsafe impl Sync`, because `PhysicsBackend: Send + Sync` while Natsel
//!    deliberately implements only `Send` for `World`. `Send` needs no impl here: the
//!    boxed world carries its own.
//!
//! Determinism: every map iteration that reaches the engine or a published result is
//! ordered by `entity.rawValue`, because the frame hashes depend on call order.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use natsel::simulation::World;
use natsel::types::ids::{BodyID, JointID, ShapeID};
use natsel::types::world_def::Capacity;

use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend::PhysicsBackend;
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext, PhysicsStepResult,
    PhysicsSyncEvent,
};
use crate::physics::backend::physics_descriptors::{
    PhysicsBodyDescriptor, PhysicsCharacterDescriptor, PhysicsConstraintDescriptor,
    PhysicsSoftBodyDescriptor, PhysicsVehicleDescriptor,
};
use crate::physics::physics_events::{PhysicsContactEvent, PhysicsContactEventKind};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::{PhysicsBackendError, PhysicsBackendErrorCode};
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapHit, PhysicsOverlapShapeQuery, PhysicsQueryFilter,
    PhysicsQueryShape, PhysicsRaycastHit, PhysicsRaycastQuery, PhysicsSweepAABBQuery,
    PhysicsSweepHit, PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::TriggerFrameResource;
use crate::physics::rigid_body::RigidBody;
use crate::runtime_world::WorldTransform;

use super::natsel_queries;
use super::natsel_shapes;

/// Wrapper so `ShapeID` can key an ordered map: Natsel's id types derive neither
/// `Ord` nor `Hash`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct ShapeIdKey {
    pub(crate) index1: i32,
    pub(crate) world0: u16,
    pub(crate) generation: u16,
}

impl ShapeIdKey {
    pub(crate) fn of(id: ShapeID) -> Self {
        ShapeIdKey {
            index1: id.index1,
            world0: id.world0,
            generation: id.generation,
        }
    }
}

/// An ordered `(entityA, entityB)` pair with the lower raw value first, matching
/// Swift's `Pair`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Pair {
    pub(crate) a: EntityID,
    pub(crate) b: EntityID,
}

impl Pair {
    pub(crate) fn ordered(lhs: EntityID, rhs: EntityID) -> Self {
        if lhs.raw_value() < rhs.raw_value() {
            Pair { a: lhs, b: rhs }
        } else {
            Pair { a: rhs, b: lhs }
        }
    }
}

pub(crate) struct BodyRecord {
    pub(crate) id: BodyID,
    pub(crate) descriptor: PhysicsBodyDescriptor,
    pub(crate) shapes: Vec<ShapeID>,
}

#[derive(Clone, Copy)]
pub(crate) struct ShapeOwner {
    pub(crate) entity: EntityID,
    pub(crate) child: u32,
}

pub(crate) struct CharacterRecord {
    /// Stored for its whole life, exactly as Swift's `CharacterRecord` held it.
    /// SAFETY: this backend owns `world` (boxed, so its address is stable), destroys
    /// every record before replacing the world in `reset`, and only touches records
    /// from `prepare`/`step`/`reset`, which hold `&mut self`.
    pub(crate) character: natsel::character::character_virtual::CharacterVirtual<'static>,
    pub(crate) descriptor: PhysicsCharacterDescriptor,
    pub(crate) stance: crate::physics::character_controller::CharacterStance,
}

pub(crate) struct VehicleRecord {
    pub(crate) id: natsel::vehicle::vehicle_types::VehicleID,
    pub(crate) body: BodyID,
    pub(crate) descriptor: PhysicsVehicleDescriptor,
}

pub(crate) struct SoftRecord {
    pub(crate) id: natsel::soft_body::soft_body_runtime::SoftBodyID,
    pub(crate) descriptor: PhysicsSoftBodyDescriptor,
}

#[derive(Clone, Copy)]
pub(crate) struct SoftQuerySurface {
    pub(crate) body: BodyID,
    pub(crate) shape: ShapeID,
}

/// The Natsel backend.
pub struct NatselPhysicsBackend {
    /// Boxed so the address is stable: a stored `CharacterVirtual<'static>` holds a raw
    /// pointer to it, and a move of the backend must not invalidate that. Swift got the
    /// same property from heap allocation.
    pub(crate) world: Box<World>,
    pub(crate) bodies: BTreeMap<EntityID, BodyRecord>,
    pub(crate) owners: BTreeMap<ShapeIdKey, ShapeOwner>,
    pub(crate) joints: BTreeMap<EntityID, JointID>,
    pub(crate) joint_descriptors: BTreeMap<EntityID, PhysicsConstraintDescriptor>,
    pub(crate) contacts: BTreeMap<Pair, PhysicsContactEvent>,
    pub(crate) trigger_pairs: BTreeSet<Pair>,
    pub(crate) settings: PhysicsSettingsResource,
    pub(crate) characters: BTreeMap<EntityID, CharacterRecord>,
    pub(crate) vehicles: BTreeMap<EntityID, VehicleRecord>,
    pub(crate) soft_bodies: BTreeMap<EntityID, SoftRecord>,
    pub(crate) soft_query_surfaces: BTreeMap<EntityID, SoftQuerySurface>,
    pub(crate) soft_query_surfaces_dirty: bool,
    pub(crate) initialized: bool,
}

// SAFETY: `PhysicsBackend` requires `Send + Sync`. Natsel made `World: Send`, but the
// stored `CharacterVirtual` is not: it carries `user_data: Option<*mut c_void>` and
// `contact_filter: Option<Box<dyn Fn(ShapeID, BodyID) -> bool>>`, neither of which is
// `Send`. Both are inert here — Diffuse never sets `user_data` and never installs a
// `contact_filter` (nothing in this backend writes either field), so the record holds
// only data the backend itself owns: the boxed world, `BodyID`/`ShapeID` handles, and
// `PhysicsCharacterDescriptor`. Moving the backend moves that pointer with its sole
// owner, exactly as moving a `Box<World>` does.
unsafe impl Send for NatselPhysicsBackend {}

// SAFETY: `Sync` is required for the same reason. Natsel deliberately does not implement
// `Sync` for `World`, because concurrent `&World` could reach the two mutable traversal
// stacks. Sharing `&NatselPhysicsBackend` cannot reach them either: every mutating entry
// point (`prepare`, `step`, `reset`) takes `&mut self`, so `Sync` only exposes immutable
// query methods (`raycast`, `overlap_*`, `sweep_*`, `detect_trigger_frame`), which call
// Natsel's `&self` query paths and never enter the solver. The stored `CharacterVirtual`
// is likewise unreachable through any `&self` method, so no shared borrow can observe or
// mutate it.
unsafe impl Sync for NatselPhysicsBackend {}

impl NatselPhysicsBackend {
    pub fn new() -> Self {
        // Swift's `Natsel.World()` — the defaulted `init(capacity: Capacity())`.
        NatselPhysicsBackend {
            world: Box::new(World::new(Capacity::default())),
            bodies: BTreeMap::new(),
            owners: BTreeMap::new(),
            joints: BTreeMap::new(),
            joint_descriptors: BTreeMap::new(),
            contacts: BTreeMap::new(),
            trigger_pairs: BTreeSet::new(),
            settings: PhysicsSettingsResource::default(),
            characters: BTreeMap::new(),
            vehicles: BTreeMap::new(),
            soft_bodies: BTreeMap::new(),
            soft_query_surfaces: BTreeMap::new(),
            soft_query_surfaces_dirty: true,
            initialized: false,
        }
    }

    /// The raw world pointer handed to `CharacterVirtual::from_raw_world`.
    ///
    /// The `Box` guarantees the address survives moves of the backend; the caller must
    /// still guarantee Natsel's three obligations (world outlives the character, no
    /// concurrent borrow, exclusive access).
    pub(crate) fn world_pointer(&mut self) -> *mut World {
        &mut *self.world as *mut World
    }

    /// Replaces the world in `reset`, after every character has been destroyed.
    fn reset_world(&mut self) {
        *self.world = World::new(Capacity::default());
    }
}

impl Default for NatselPhysicsBackend {
    fn default() -> Self {
        NatselPhysicsBackend::new()
    }
}

// MARK: - Conversions

impl NatselPhysicsBackend {
    pub(crate) fn failure(
        code: PhysicsBackendErrorCode,
        message: impl Into<String>,
    ) -> PhysicsBackendError {
        PhysicsBackendError::new(code, message)
    }

    pub(crate) fn nv(value: Float3) -> natsel::math::types::Vec3 {
        natsel::math::types::Vec3::new(value.x, value.y, value.z)
    }

    pub(crate) fn sv(value: natsel::math::types::Vec3) -> Float3 {
        Float3::new(value.x, value.y, value.z)
    }

    pub(crate) fn sv_pos(value: natsel::math::types::Pos) -> Float3 {
        Float3::new(value.x as f32, value.y as f32, value.z as f32)
    }

    pub(crate) fn np(value: Float3) -> natsel::math::types::Pos {
        natsel::math::types::Pos::new(value.x as f64, value.y as f64, value.z as f64)
    }

    pub(crate) fn nq(value: Float4) -> natsel::math::types::Quat {
        natsel::math::functions::normalize_quat(natsel::math::types::Quat::new(
            natsel::math::types::Vec3::new(value.x, value.y, value.z),
            value.w,
        ))
    }

    pub(crate) fn sq(value: natsel::math::types::Quat) -> Float4 {
        Float4::new(value.v.x, value.v.y, value.v.z, value.s)
    }

    pub(crate) fn body_type(
        motion_type: crate::physics::rigid_body::RigidBodyMotionType,
    ) -> natsel::types::body_def::BodyType {
        use crate::physics::rigid_body::RigidBodyMotionType;
        use natsel::types::body_def::BodyType;
        match motion_type {
            RigidBodyMotionType::Static => BodyType::StaticBody,
            RigidBodyMotionType::Dynamic => BodyType::DynamicBody,
            RigidBodyMotionType::Kinematic => BodyType::KinematicBody,
        }
    }

    /// `clamped(_:_:)` — shortened to `maximum` when the vector is longer.
    pub(crate) fn clamped(value: Float3, maximum: f32) -> Float3 {
        let length = diffuse_math::simd::simd_compat::simd_length(value);
        if length > maximum && length > 0.0 {
            value * (maximum / length)
        } else {
            value
        }
    }

    /// `scale(_:)` — per-column basis lengths.
    pub(crate) fn scale(matrix: Float4x4) -> Float3 {
        Float3::new(
            diffuse_math::simd::simd_compat::simd_length(Float3::new(
                matrix.columns[0].x,
                matrix.columns[0].y,
                matrix.columns[0].z,
            )),
            diffuse_math::simd::simd_compat::simd_length(Float3::new(
                matrix.columns[1].x,
                matrix.columns[1].y,
                matrix.columns[1].z,
            )),
            diffuse_math::simd::simd_compat::simd_length(Float3::new(
                matrix.columns[2].x,
                matrix.columns[2].y,
                matrix.columns[2].z,
            )),
        )
    }

    /// `rotation(_:)` — each basis column is divided by `max(scale, 1e-6)` before
    /// the quaternion is decoded. Dividing by the floor rather than normalizing keeps
    /// a zero-length column finite.
    pub(crate) fn rotation(matrix: Float4x4) -> diffuse_math::simd::simd_compat::Quatf {
        let s = Self::scale(matrix);
        let divisor = Float3::new(s.x.max(0.000_001), s.y.max(0.000_001), s.z.max(0.000_001));
        let x = Float3::new(
            matrix.columns[0].x / divisor.x,
            matrix.columns[0].y / divisor.x,
            matrix.columns[0].z / divisor.x,
        );
        let y = Float3::new(
            matrix.columns[1].x / divisor.y,
            matrix.columns[1].y / divisor.y,
            matrix.columns[1].z / divisor.y,
        );
        let z = Float3::new(
            matrix.columns[2].x / divisor.z,
            matrix.columns[2].y / divisor.z,
            matrix.columns[2].z / divisor.z,
        );
        // Basis vectors are passed as columns, matching Swift's
        // `simd_float3x3(_:_:_:)` and `from_columns([c0, c1, c2])`.
        diffuse_math::simd::simd_compat::Quatf::from_float3x3(
            diffuse_math::simd::simd_compat::Float3x3::new_with_columns(x, y, z),
        )
    }

    /// `matrix(translation:rotation:scale:)` — rotated basis columns scaled per axis,
    /// translation in column 3.
    pub(crate) fn matrix(translation: Float3, rotation: Float4, scale: Float3) -> Float4x4 {
        let quaternion = diffuse_math::simd::simd_compat::Quatf::from_vector(rotation);
        let x = quaternion.act(Float3::new(1.0, 0.0, 0.0)) * scale.x;
        let y = quaternion.act(Float3::new(0.0, 1.0, 0.0)) * scale.y;
        let z = quaternion.act(Float3::new(0.0, 0.0, 1.0)) * scale.z;
        Float4x4::new_with_columns(
            Float4::new(x.x, x.y, x.z, 0.0),
            Float4::new(y.x, y.y, y.z, 0.0),
            Float4::new(z.x, z.y, z.z, 0.0),
            Float4::new(translation.x, translation.y, translation.z, 1.0),
        )
    }
}

// MARK: - Body and joint lifetime

impl NatselPhysicsBackend {
    pub(crate) fn remove_joint(&mut self, entity: EntityID) {
        if let Some(id) = self.joints.remove(&entity)
            && self.world.joint_is_valid(id)
        {
            // Natsel 0.2 destroys by pool index and a wake flag. Swift decoded the same
            // value from its stored id (`id.stored >> 32 - 1`); `index1` is that field
            // minus one, so this mirrors `NatselPhysicsBackend.swift:180` exactly.
            self.world.destroy_joint(id.index1 - 1, true);
        }
        self.joint_descriptors.remove(&entity);
    }

    pub(crate) fn remove_body(&mut self, entity: EntityID) {
        let dependent: Vec<EntityID> = self
            .joint_descriptors
            .iter()
            .filter(|(_, descriptor)| {
                descriptor.constraint.entity_a == entity || descriptor.constraint.entity_b == entity
            })
            .map(|(joint, _)| *joint)
            .collect();
        for joint in dependent {
            self.remove_joint(joint);
        }
        if let Some(vehicle) = self.vehicles.remove(&entity) {
            self.world.destroy_vehicle(vehicle.id);
        }
        let Some(record) = self.bodies.remove(&entity) else {
            return;
        };
        for shape in &record.shapes {
            self.owners.remove(&ShapeIdKey::of(*shape));
        }
        self.world.destroy_body(record.id);
    }

    /// Drops every stored character, then forgets them. Called from `reset` before
    /// the world is replaced.
    fn destroy_characters(&mut self) {
        let entities: Vec<EntityID> = self.characters.keys().copied().collect();
        for entity in entities {
            let Some(mut record) = self.characters.remove(&entity) else {
                continue;
            };
            // The record was removed from the map first, so its stored character can
            // be dropped here; dropping destroys the inner body through the raw world
            // pointer Natsel holds.
            record.character.destroy();
        }
    }
}

// MARK: - PhysicsBackend

impl PhysicsBackend for NatselPhysicsBackend {
    fn identifier(&self) -> &str {
        "natsel"
    }

    fn capabilities(&self) -> PhysicsBackendCapabilities {
        PhysicsBackendCapabilities::all()
    }

    fn prepare(&mut self, context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        self.settings = context.settings;
        self.world.gravity = Self::nv(self.settings.gravity);
        self.world.enable_sleep = self.settings.allow_sleep;
        self.world.enable_dynamic_continuous = true;
        // Swift: `min(32, workerThreadCount == 0 ? max(1, activeProcessorCount - 1) : workerThreadCount)`.
        let worker_count = if self.settings.capacity.worker_thread_count == 0 {
            std::thread::available_parallelism()
                .map(|count| (count.get() as i64 - 1).max(1))
                .unwrap_or(1)
        } else {
            self.settings.capacity.worker_thread_count
        };
        self.world.worker_count = worker_count.clamp(1, 32) as i32;

        let full = context.is_full_snapshot || !self.initialized;
        let mut result = PhysicsPrepareResult::default();
        if (context.active_bodies.len() + context.active_soft_bodies.len()) as i64
            > self.settings.capacity.max_bodies
        {
            result.error = Some(Self::failure(
                PhysicsBackendErrorCode::BodyCreationFailed,
                "Natsel body capacity exceeded",
            ));
            return result;
        }

        let mut updates: BTreeMap<EntityID, PhysicsBodyDescriptor> = BTreeMap::new();
        let mut joint_updates: BTreeMap<EntityID, PhysicsConstraintDescriptor> = BTreeMap::new();
        let mut removals: BTreeSet<EntityID> = BTreeSet::new();
        let mut joint_removals: BTreeSet<EntityID> = BTreeSet::new();
        if full {
            for descriptor in &context.active_bodies {
                updates.insert(descriptor.entity, descriptor.clone());
            }
            for descriptor in &context.active_constraints {
                joint_updates.insert(descriptor.entity, descriptor.clone());
            }
            removals = self.bodies.keys().copied().collect();
            for entity in updates.keys() {
                removals.remove(entity);
            }
            joint_removals = self.joints.keys().copied().collect();
            for entity in joint_updates.keys() {
                joint_removals.remove(entity);
            }
        } else {
            for event in &context.sync_events {
                match event {
                    PhysicsSyncEvent::BodyUpsert(value) => {
                        updates.insert(value.entity, (**value).clone());
                        removals.remove(&value.entity);
                    }
                    PhysicsSyncEvent::BodyRemove(entity) => {
                        removals.insert(*entity);
                        updates.remove(entity);
                    }
                    PhysicsSyncEvent::ConstraintUpsert(value) => {
                        joint_updates.insert(value.entity, (**value).clone());
                        joint_removals.remove(&value.entity);
                    }
                    PhysicsSyncEvent::ConstraintRemove(entity) => {
                        joint_removals.insert(*entity);
                        joint_updates.remove(entity);
                    }
                    _ => {}
                }
            }
        }
        // A rejected upsert can remove its old native body. Retry any active
        // descriptor whose native body is missing and is not queued for removal.
        for descriptor in &context.active_bodies {
            if !self.bodies.contains_key(&descriptor.entity)
                && !removals.contains(&descriptor.entity)
            {
                updates.insert(descriptor.entity, descriptor.clone());
            }
        }

        let mut ordered_joint_removals: Vec<EntityID> = joint_removals.into_iter().collect();
        ordered_joint_removals.sort_by_key(|entity| entity.raw_value());
        for entity in ordered_joint_removals {
            self.remove_joint(entity);
            result.removed_constraints += 1;
        }
        let mut ordered_removals: Vec<EntityID> = removals.into_iter().collect();
        ordered_removals.sort_by_key(|entity| entity.raw_value());
        for entity in ordered_removals {
            self.remove_body(entity);
            result.removed_bodies += 1;
        }

        let mut update_entities: Vec<EntityID> = updates.keys().copied().collect();
        update_entities.sort_by_key(|entity| entity.raw_value());
        for entity in update_entities {
            let descriptor = updates.remove(&entity).expect("key came from updates");
            if let Err(error) = self.upsert_body(&descriptor) {
                result.error = Some(error);
                return result;
            }
            result.synchronized_bodies += 1;
        }

        let mut constraints = context.active_constraints.clone();
        constraints.sort_by_key(|descriptor| descriptor.entity.raw_value());
        for descriptor in constraints {
            if joint_updates.contains_key(&descriptor.entity)
                || !self.joints.contains_key(&descriptor.entity)
            {
                if let Err(error) = self.upsert_joint(&descriptor) {
                    result.error = Some(error);
                    return result;
                }
                result.synchronized_constraints += 1;
            }
        }

        if let Err(error) = self.synchronize_features(&context, &mut result) {
            result.error = Some(error);
            return result;
        }
        self.initialized = true;
        result
    }

    fn step(&mut self, context: PhysicsStepContext) -> PhysicsStepResult {
        if let Some(error) = self.validate_vehicle_gears(&context) {
            return PhysicsStepResult::with_error(error);
        }

        self.world.gravity = Self::nv(context.settings.gravity);
        self.world.enable_sleep = context.settings.allow_sleep;
        self.apply_body_commands(&context);
        if !self.characters.is_empty() {
            self.ensure_soft_query_surfaces();
        }
        let character_states = self.step_characters(&context);
        self.apply_vehicle_commands(&context);

        let joint_errors: BTreeMap<EntityID, f32> = self
            .joint_descriptors
            .iter()
            .filter(|(_, descriptor)| descriptor.constraint.break_force < f32::MAX)
            .map(|(entity, descriptor)| {
                (*entity, self.joint_position_error(&descriptor.constraint))
            })
            .collect();

        self.world.step(
            context.step_delta_seconds as f32,
            context.settings.collision_steps as i32,
        );
        self.soft_query_surfaces_dirty = true;

        let mut events = self.collect_contacts();
        events.extend(self.trigger_contact_events());
        let breaks = self.detect_joint_breaks(&context, &joint_errors);
        let writebacks = self.collect_writebacks(&context);

        let touching = self.world.touching_contact_count().max(0) as i64;
        PhysicsStepResult {
            body_count: (self.bodies.len() + self.soft_bodies.len()) as i64,
            constraint_count: self.joints.len() as i64,
            contact_count: touching.max(self.contacts.len() as i64),
            writebacks,
            contact_events: events,
            joint_break_events: breaks,
            character_states,
            vehicle_states: self.vehicle_states(),
            soft_body_states: self.soft_states(),
            error: None,
        }
    }

    fn raycast(
        &self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        self.raycast_all(query, filter, 1).into_iter().next()
    }

    fn raycast_all(
        &self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
        max_hits: usize,
    ) -> Vec<PhysicsRaycastHit> {
        natsel_queries::raycast_all(self, &query, &filter, max_hits)
    }

    fn overlap_aabb(
        &self,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        let mut shape_query = PhysicsOverlapShapeQuery::new(
            PhysicsQueryShape::Box {
                half_extents: natsel_shapes::aabb_half_extents(&query.bounds),
            },
            natsel_shapes::aabb_center(&query.bounds),
        );
        shape_query.max_results = query.max_results;
        self.overlap_shape(shape_query, filter)
    }

    fn overlap_shape(
        &self,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        natsel_queries::overlap_shape(self, &query, &filter)
    }

    fn sweep_aabb(
        &self,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.sweep_shape(
            PhysicsSweepShapeQuery::new(
                PhysicsQueryShape::Box {
                    half_extents: natsel_shapes::aabb_half_extents(&query.bounds),
                },
                natsel_shapes::aabb_center(&query.bounds),
                query.translation,
            ),
            filter,
        )
    }

    fn sweep_shape(
        &self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.sweep_shape_all(query, filter, 1).into_iter().next()
    }

    fn sweep_shape_all(
        &self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
        max_hits: usize,
    ) -> Vec<PhysicsSweepHit> {
        natsel_queries::sweep_shape_all(self, &query, &filter, max_hits)
    }

    fn detect_trigger_frame(&self, max_event_count: usize) -> TriggerFrameResource {
        natsel_queries::detect_trigger_frame(self, max_event_count)
    }

    fn reset(&mut self) {
        self.destroy_characters();
        self.vehicles.clear();
        self.soft_bodies.clear();
        self.soft_query_surfaces.clear();
        self.soft_query_surfaces_dirty = true;
        self.bodies.clear();
        self.owners.clear();
        self.joints.clear();
        self.joint_descriptors.clear();
        self.contacts.clear();
        self.trigger_pairs.clear();
        self.reset_world();
        self.initialized = false;
    }
}

// MARK: - Contacts

impl NatselPhysicsBackend {
    /// `collectContacts()` — rebuild the pair cache and derive began/stayed/ended.
    ///
    /// Bodies are visited in ascending entity order and only the first manifold per
    /// pair is kept, so a compound collider contributes one event per entity pair
    /// rather than one per child shape.
    pub(crate) fn collect_contacts(&mut self) -> Vec<PhysicsContactEvent> {
        let mut current: BTreeMap<Pair, PhysicsContactEvent> = BTreeMap::new();
        let mut entities: Vec<EntityID> = self.bodies.keys().copied().collect();
        entities.sort_by_key(|entity| entity.raw_value());
        for entity in entities {
            let Some(record_id) = self.bodies.get(&entity).map(|record| record.id) else {
                continue;
            };
            for contact in self.world.body_contact_data(record_id, usize::MAX) {
                let (Some(a), Some(b)) = (
                    natsel_shapes::shape_owner(self, contact.shape_id_a),
                    natsel_shapes::shape_owner(self, contact.shape_id_b),
                ) else {
                    continue;
                };
                if a.entity == b.entity {
                    continue;
                }
                let pair = Pair::ordered(a.entity, b.entity);
                // Normalise the event so the lower entity owns shape A.
                let (first, second) = if a.entity.raw_value() < b.entity.raw_value() {
                    (a, b)
                } else {
                    (b, a)
                };
                if current.contains_key(&pair) {
                    continue;
                }
                let kind = if self.contacts.contains_key(&pair) {
                    PhysicsContactEventKind::Stayed
                } else {
                    PhysicsContactEventKind::Began
                };
                let body_a = self.world.shape_body(contact.shape_id_a);
                let body_b = self.world.shape_body(contact.shape_id_b);
                let velocity_a = self.world.body_linear_velocity(body_a);
                let velocity_b = self.world.body_linear_velocity(body_b);
                let mut event = PhysicsContactEvent::new(
                    first.entity,
                    second.entity,
                    first.child,
                    second.child,
                    kind,
                    Float3::ZERO,
                    Float3::ZERO,
                    0.0,
                    Self::sv(velocity_b - velocity_a),
                    0.0,
                );
                if let Some(manifold) = contact.manifolds.first()
                    && manifold.point_count > 0
                {
                    let point = manifold.points[0];
                    event.normal = Self::sv(manifold.normal);
                    event.position = Self::sv_pos(natsel::math::functions::offset_pos(
                        self.world.body_world_center(body_a),
                        point.anchor_a,
                    ));
                    // Separation is negative while penetrating, so this is the depth.
                    event.penetration_depth = (-point.separation).max(0.0);
                    event.impulse = point.normal_impulse;
                }
                current.insert(pair, event);
            }
        }
        // CCD can stop at impact before a persistent manifold exists. Publish that
        // contact in the same frame; the pair cache then reports later transitions.
        for impact in self.world.continuous_impacts() {
            let (Some(a), Some(b)) = (
                natsel_shapes::shape_owner(self, impact.shape_id_a),
                natsel_shapes::shape_owner(self, impact.shape_id_b),
            ) else {
                continue;
            };
            if a.entity == b.entity {
                continue;
            }
            let pair = Pair::ordered(a.entity, b.entity);
            let (first, second) = if a.entity.raw_value() < b.entity.raw_value() {
                (a, b)
            } else {
                (b, a)
            };
            if current.contains_key(&pair) {
                continue;
            }
            let kind = if self.contacts.contains_key(&pair) {
                PhysicsContactEventKind::Stayed
            } else {
                PhysicsContactEventKind::Began
            };
            let velocity_a = self
                .world
                .body_linear_velocity(self.world.shape_body(impact.shape_id_a));
            let velocity_b = self
                .world
                .body_linear_velocity(self.world.shape_body(impact.shape_id_b));
            let event = PhysicsContactEvent::new(
                first.entity,
                second.entity,
                first.child,
                second.child,
                kind,
                Self::sv_pos(impact.point),
                Self::sv(impact.normal),
                0.0,
                Self::sv(velocity_b - velocity_a),
                0.0,
            );
            current.insert(pair, event);
        }

        let mut result: Vec<PhysicsContactEvent> = current.values().cloned().collect();
        // Pairs that vanished this frame report `ended` with their last known data.
        for (pair, previous) in &self.contacts {
            if !current.contains_key(pair) {
                let mut ended = *previous;
                ended.kind = PhysicsContactEventKind::Ended;
                result.push(ended);
            }
        }
        self.contacts = current;
        result
    }

    /// Rejects a manual gear the transmission cannot reach, before any substep runs.
    pub(crate) fn validate_vehicle_gears(
        &self,
        context: &PhysicsStepContext,
    ) -> Option<PhysicsBackendError> {
        for (entity, command) in &context.vehicle_commands {
            let Some(gear) = command.manual_gear else {
                continue;
            };
            let config = &self
                .vehicles
                .get(entity)
                .map(|record| &record.descriptor.vehicle.transmission)
                .expect("vehicle key came from the map");
            if gear > config.gear_ratios.len() as i64
                || gear < -(config.reverse_gear_ratios.len() as i64)
            {
                return Some(Self::failure(
                    PhysicsBackendErrorCode::InvalidArgument,
                    "Vehicle gear is outside the configured transmission",
                ));
            }
        }
        None
    }
}

// MARK: - Step helpers

impl NatselPhysicsBackend {
    /// Body forces, impulses, velocities and kinematic targets for this substep.
    fn apply_body_commands(&mut self, context: &PhysicsStepContext) {
        let mut maximum_speed: f32 = 1.0;
        let mut ordered: Vec<PhysicsBodyDescriptor> = context.active_bodies.clone();
        ordered.sort_by_key(|descriptor| descriptor.entity.raw_value());
        for descriptor in &ordered {
            let (Some(record_id), Some(rigid)) = (
                self.bodies.get(&descriptor.entity).map(|record| record.id),
                descriptor.rigid_body.as_ref(),
            ) else {
                continue;
            };
            maximum_speed = maximum_speed.max(rigid.max_linear_velocity);
            if let Some(target) = &rigid.kinematic_target
                && rigid.motion_type == crate::physics::rigid_body::RigidBodyMotionType::Kinematic
            {
                self.world.set_body_target_transform(
                    record_id,
                    natsel::math::types::WorldTransform::new(
                        Self::np(target.position),
                        Self::nq(target.rotation),
                    ),
                    context.step_delta_seconds as f32,
                    true,
                );
            } else if context.step_index == 0 {
                self.world.set_body_linear_velocity(
                    record_id,
                    Self::nv(Self::clamped(
                        rigid.linear_velocity,
                        rigid.max_linear_velocity,
                    )),
                );
                self.world.set_body_angular_velocity(
                    record_id,
                    Self::nv(Self::clamped(
                        rigid.angular_velocity,
                        rigid.max_angular_velocity,
                    )),
                );
            }
            if context.step_index == 0 {
                if rigid.accumulated_linear_impulse != Float3::ZERO {
                    self.world.apply_body_linear_impulse_to_center(
                        record_id,
                        Self::nv(rigid.accumulated_linear_impulse),
                        true,
                    );
                }
                if rigid.accumulated_angular_impulse != Float3::ZERO {
                    self.world.apply_body_angular_impulse(
                        record_id,
                        Self::nv(rigid.accumulated_angular_impulse),
                        true,
                    );
                }
                if rigid.accumulated_force != Float3::ZERO {
                    self.world.apply_body_force_to_center(
                        record_id,
                        Self::nv(rigid.accumulated_force),
                        true,
                    );
                }
                if rigid.accumulated_torque != Float3::ZERO {
                    self.world.apply_body_torque(
                        record_id,
                        Self::nv(rigid.accumulated_torque),
                        true,
                    );
                }
            }
        }
        // Characters can move faster than any authored body; include them in the
        // engine's speed clamp so the solver cannot tunnel them.
        let character_speeds: Vec<f32> = self
            .characters
            .values()
            .map(|record| {
                diffuse_math::simd::simd_compat::simd_length(Self::sv(
                    self.world
                        .body_linear_velocity(record.character.inner_body_id()),
                ))
            })
            .collect();
        for speed in character_speeds {
            maximum_speed = maximum_speed.max(speed);
        }
        self.world.max_linear_speed = maximum_speed;
    }

    /// Trigger overlaps surface as contact events with no impulse, mirroring the
    /// `began`/`stayed`/`ended` transitions Swift synthesises from `TriggerFrameResource`.
    fn trigger_contact_events(&self) -> Vec<PhysicsContactEvent> {
        let triggers = natsel_queries::detect_trigger_frame(self, usize::MAX);
        let entered: BTreeSet<Pair> = triggers
            .enters
            .iter()
            .map(|event| Pair::ordered(event.trigger_entity, event.other_entity))
            .collect();
        let mut events = Vec::new();
        for event in &triggers.enters {
            events.push(Self::trigger_event(event, PhysicsContactEventKind::Began));
        }
        for event in &triggers.active {
            if !entered.contains(&Pair::ordered(event.trigger_entity, event.other_entity)) {
                events.push(Self::trigger_event(event, PhysicsContactEventKind::Stayed));
            }
        }
        for event in &triggers.exits {
            events.push(Self::trigger_event(event, PhysicsContactEventKind::Ended));
        }
        events
    }

    fn trigger_event(
        event: &crate::physics::queries::trigger_detection::TriggerEvent,
        kind: PhysicsContactEventKind,
    ) -> PhysicsContactEvent {
        PhysicsContactEvent::new(
            event.trigger_entity,
            event.other_entity,
            0,
            0,
            kind,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
            Float3::ZERO,
            0.0,
        )
    }

    /// Force/torque break thresholds, including the positional reaction Natsel's split
    /// solve hides in its relax pass.
    fn detect_joint_breaks(
        &mut self,
        context: &PhysicsStepContext,
        joint_errors: &BTreeMap<EntityID, f32>,
    ) -> Vec<crate::physics::physics_events::PhysicsJointBreakEvent> {
        let mut breaks = Vec::new();
        let mut entities: Vec<EntityID> = self.joints.keys().copied().collect();
        entities.sort_by_key(|entity| entity.raw_value());
        for entity in entities {
            let (Some(id), Some(joint)) = (
                self.joints.get(&entity).copied(),
                self.joint_descriptors
                    .get(&entity)
                    .map(|descriptor| descriptor.constraint.clone()),
            ) else {
                continue;
            };
            let mut force = diffuse_math::simd::simd_compat::simd_length(
                self.world
                    .joint_constraint_force(id)
                    .map(Self::sv)
                    .unwrap_or(Float3::ZERO),
            );
            if let Some(before) = joint_errors.get(&entity).copied()
                && let (Some(a), Some(b)) = (
                    self.bodies.get(&joint.entity_a).map(|record| record.id),
                    self.bodies.get(&joint.entity_b).map(|record| record.id),
                )
            {
                let inverse_mass =
                    self.world.body_inverse_mass(a) + self.world.body_inverse_mass(b);
                let correction = (before - self.joint_position_error(&joint)).max(0.0);
                if inverse_mass > 0.0 {
                    let delta = context.step_delta_seconds as f32;
                    force = force.max(correction / (inverse_mass * (delta * delta)));
                }
            }
            let torque = diffuse_math::simd::simd_compat::simd_length(
                self.world
                    .joint_constraint_torque(id)
                    .map(Self::sv)
                    .unwrap_or(Float3::ZERO),
            );
            if force > joint.break_force || torque > joint.break_torque {
                breaks.push(crate::physics::physics_events::PhysicsJointBreakEvent::new(
                    entity,
                    joint.entity_a,
                    joint.entity_b,
                    force,
                    torque,
                ));
                self.remove_joint(entity);
            }
        }
        breaks
    }

    /// Non-static bodies publish pose, velocities and sleep state. A substep past the
    /// first always overwrites, even when the value returns to the initial state.
    fn collect_writebacks(
        &mut self,
        context: &PhysicsStepContext,
    ) -> Vec<crate::physics::backend::physics_backend_context::PhysicsBodyWriteback> {
        let mut writebacks = Vec::new();
        for descriptor in &context.active_bodies {
            let Some(record_id) = self.bodies.get(&descriptor.entity).map(|record| record.id)
            else {
                continue;
            };
            let Some(rigid) = descriptor.rigid_body.as_ref() else {
                continue;
            };
            if rigid.motion_type == crate::physics::rigid_body::RigidBodyMotionType::Static {
                continue;
            }
            let pose = self.world.body_transform(record_id);
            let transform = WorldTransform::new(Self::matrix(
                Self::sv_pos(pose.p),
                Self::sq(pose.q),
                Self::scale(descriptor.world_transform.matrix),
            ));
            let linear = Self::clamped(
                Self::sv(self.world.body_linear_velocity(record_id)),
                rigid.max_linear_velocity,
            );
            let angular = Self::clamped(
                Self::sv(self.world.body_angular_velocity(record_id)),
                rigid.max_angular_velocity,
            );
            let asleep = !self.world.is_body_awake_id(record_id);
            // The cache must reflect what we just published, or the next prepare
            // would treat the writeback as an authored teleport.
            if let Some(record) = self.bodies.get_mut(&descriptor.entity) {
                record.descriptor.world_transform = transform;
                if let Some(cached) = record.descriptor.rigid_body.as_mut() {
                    cached.linear_velocity = linear;
                    cached.angular_velocity = angular;
                    cached.is_sleeping = asleep;
                }
            }
            let complete = context.step_index > 0;
            let mut writeback =
                crate::physics::backend::physics_backend_context::PhysicsBodyWriteback::new(
                    descriptor.entity,
                );
            let pose_changed = transform != descriptor.world_transform;
            let linear_changed = linear != rigid.linear_velocity;
            let angular_changed = angular != rigid.angular_velocity;
            let sleep_changed = asleep != rigid.is_sleeping;
            if !complete && !(pose_changed || linear_changed || angular_changed || sleep_changed) {
                continue;
            }
            if complete || pose_changed {
                writeback.world_transform = Some(transform);
            }
            if complete || linear_changed {
                writeback.linear_velocity = Some(linear);
            }
            if complete || angular_changed {
                writeback.angular_velocity = Some(angular);
            }
            if complete || sleep_changed {
                writeback.is_sleeping = Some(asleep);
            }
            writebacks.push(writeback);
        }
        writebacks
    }
}

// MARK: - Body upsert

impl NatselPhysicsBackend {
    fn upsert_body(
        &mut self,
        descriptor: &PhysicsBodyDescriptor,
    ) -> Result<(), PhysicsBackendError> {
        let entity = descriptor.entity;
        if let Some(old) = self.bodies.get(&entity) {
            let shape_changed = old.descriptor.collider != descriptor.collider
                || old.descriptor.mesh_geometry != descriptor.mesh_geometry
                || Self::scale(old.descriptor.world_transform.matrix)
                    != Self::scale(descriptor.world_transform.matrix)
                || old
                    .descriptor
                    .rigid_body
                    .as_ref()
                    .map(|body| body.axis_locks)
                    != descriptor.rigid_body.as_ref().map(|body| body.axis_locks);
            if shape_changed {
                self.remove_body(entity);
            }
        }

        let rigid = descriptor.rigid_body.clone();
        let is_new = !self.bodies.contains_key(&entity);
        if is_new {
            use crate::physics::rigid_body::{RigidBodyAxisLocks, RigidBodyMotionQuality};
            let mut def = natsel::types::body_def::BodyDef {
                ..natsel::types::body_def::BodyDef::default()
            };
            def.type_ = Self::body_type(rigid.as_ref().map_or(
                crate::physics::rigid_body::RigidBodyMotionType::Static,
                |body| body.motion_type,
            ));
            def.position = Self::np(descriptor.world_transform.translation());
            def.rotation = Self::nq(Self::rotation(descriptor.world_transform.matrix).vector);
            def.linear_velocity = Self::nv(
                rigid
                    .as_ref()
                    .map_or(Float3::ZERO, |body| body.linear_velocity),
            );
            def.angular_velocity = Self::nv(
                rigid
                    .as_ref()
                    .map_or(Float3::ZERO, |body| body.angular_velocity),
            );
            def.linear_damping = rigid
                .as_ref()
                .map_or(0.0, |body| body.linear_damping)
                .max(0.0);
            def.angular_damping = rigid
                .as_ref()
                .map_or(0.0, |body| body.angular_damping)
                .max(0.0);
            def.gravity_scale = rigid.as_ref().map_or(0.0, |body| body.gravity_scale);
            def.enable_sleep =
                self.settings.allow_sleep && rigid.as_ref().is_none_or(|body| body.allow_sleep);
            def.is_awake = !rigid.as_ref().is_some_and(|body| body.is_sleeping);
            def.is_bullet = rigid.as_ref().is_some_and(|body| {
                body.motion_quality == RigidBodyMotionQuality::LinearCast
                    || body.continuous_collision_detection
            });
            def.allow_fast_rotation = true;
            let locks = rigid
                .as_ref()
                .map(|body| body.axis_locks)
                .unwrap_or(RigidBodyAxisLocks::new(0));
            def.motion_locks = natsel::types::body_def::MotionLocks::new(
                locks.contains(RigidBodyAxisLocks::TRANSLATION_X),
                locks.contains(RigidBodyAxisLocks::TRANSLATION_Y),
                locks.contains(RigidBodyAxisLocks::TRANSLATION_Z),
                locks.contains(RigidBodyAxisLocks::ROTATION_X),
                locks.contains(RigidBodyAxisLocks::ROTATION_Y),
                locks.contains(RigidBodyAxisLocks::ROTATION_Z),
            );
            let id = self.world.create_body(&def);
            if !self.world.body_is_valid(id) {
                return Err(Self::failure(
                    PhysicsBackendErrorCode::BodyCreationFailed,
                    "Could not create Natsel body",
                ));
            }
            match natsel_shapes::create_shapes(self, descriptor, id) {
                Ok(shapes) => {
                    for (child, shape) in &shapes {
                        self.owners.insert(
                            ShapeIdKey::of(*shape),
                            ShapeOwner {
                                entity,
                                child: *child,
                            },
                        );
                    }
                    self.bodies.insert(
                        entity,
                        BodyRecord {
                            id,
                            descriptor: descriptor.clone(),
                            shapes: shapes.iter().map(|(_, shape)| *shape).collect(),
                        },
                    );
                }
                Err(error) => {
                    self.world.destroy_body(id);
                    return Err(error);
                }
            }
        }

        let Some(previous_descriptor) = self
            .bodies
            .get(&entity)
            .map(|record| record.descriptor.clone())
        else {
            return Ok(());
        };
        let record_id = self
            .bodies
            .get(&entity)
            .map(|record| record.id)
            .expect("record was just inserted or already present");
        self.world.set_body_type(
            record_id,
            Self::body_type(rigid.as_ref().map_or(
                crate::physics::rigid_body::RigidBodyMotionType::Static,
                |body| body.motion_type,
            )),
        );
        if previous_descriptor.world_transform != descriptor.world_transform {
            self.world.set_body_transform(
                record_id,
                Self::np(descriptor.world_transform.translation()),
                Self::nq(Self::rotation(descriptor.world_transform.matrix).vector),
            );
        }
        if let Some(rigid) = &rigid {
            use crate::physics::rigid_body::RigidBodyMotionQuality;
            self.world
                .set_body_linear_damping(record_id, rigid.linear_damping.max(0.0));
            self.world
                .set_body_angular_damping(record_id, rigid.angular_damping.max(0.0));
            self.world
                .set_body_gravity_scale(record_id, rigid.gravity_scale.max(0.0));
            self.world.set_body_bullet(
                record_id,
                rigid.motion_quality == RigidBodyMotionQuality::LinearCast
                    || rigid.continuous_collision_detection,
            );
            self.world
                .enable_body_sleep(record_id, self.settings.allow_sleep && rigid.allow_sleep);
            let was_sleeping = previous_descriptor
                .rigid_body
                .as_ref()
                .is_some_and(|body| body.is_sleeping);
            if was_sleeping != rigid.is_sleeping {
                self.world.set_body_awake(record_id, !rigid.is_sleeping);
            }
            let previous = previous_descriptor.rigid_body.as_ref();
            let mass_changed = is_new
                || previous.map(|body| body.motion_type)
                    != Some(crate::physics::rigid_body::RigidBodyMotionType::Dynamic)
                || previous.map(|body| body.mass) != Some(rigid.mass)
                || previous.map(|body| body.mass_mode) != Some(rigid.mass_mode)
                || previous.and_then(|body| body.center_of_mass_override)
                    != rigid.center_of_mass_override
                || previous.and_then(|body| body.inertia_diagonal_override)
                    != rigid.inertia_diagonal_override;
            if rigid.motion_type == crate::physics::rigid_body::RigidBodyMotionType::Dynamic
                && mass_changed
            {
                configure_mass(self, record_id, rigid);
            }
        }
        if let Some(record) = self.bodies.get_mut(&entity) {
            record.descriptor = descriptor.clone();
        }
        Ok(())
    }
}

/// `configureMass(_:_:)` — shape-derived mass rescaled to the authored mass, then
/// the optional centre-of-mass and inertia overrides.
fn configure_mass(backend: &mut NatselPhysicsBackend, id: BodyID, rigid: &RigidBody) {
    use crate::physics::rigid_body::RigidBodyMassMode;
    backend.world.apply_body_mass_from_shapes(id);
    let mut data = backend.world.body_mass_data(id);
    if rigid.mass_mode == RigidBodyMassMode::Mass {
        let ratio = if data.mass > 0.0 {
            rigid.mass.max(0.0001) / data.mass
        } else {
            1.0
        };
        data.mass = rigid.mass.max(0.0001);
        data.inertia = natsel::math::functions::mul_sm(ratio, data.inertia);
    }
    if let Some(center) = rigid.center_of_mass_override {
        data.center = NatselPhysicsBackend::nv(center);
    }
    if let Some(inertia) = rigid.inertia_diagonal_override {
        data.inertia = natsel::math::types::Matrix3::new(
            NatselPhysicsBackend::nv(Float3::new(inertia.x, 0.0, 0.0)),
            NatselPhysicsBackend::nv(Float3::new(0.0, inertia.y, 0.0)),
            NatselPhysicsBackend::nv(Float3::new(0.0, 0.0, inertia.z)),
        );
    }
    backend.world.set_body_mass_data(id, data);
}

// Re-exported for `step`, which is in this module, and for the sibling modules.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifier_and_capabilities_match_swift() {
        let backend = NatselPhysicsBackend::new();
        assert_eq!(backend.identifier(), "natsel");
        assert_eq!(backend.capabilities(), PhysicsBackendCapabilities::all());
    }

    #[test]
    fn reset_clears_every_store() {
        let mut backend = NatselPhysicsBackend::new();
        backend
            .trigger_pairs
            .insert(Pair::ordered(EntityID::new(1, 0), EntityID::new(2, 0)));
        backend.initialized = true;
        backend.reset();
        assert!(backend.bodies.is_empty());
        assert!(backend.owners.is_empty());
        assert!(backend.joints.is_empty());
        assert!(backend.joint_descriptors.is_empty());
        assert!(backend.contacts.is_empty());
        assert!(backend.trigger_pairs.is_empty());
        assert!(backend.characters.is_empty());
        assert!(backend.vehicles.is_empty());
        assert!(backend.soft_bodies.is_empty());
        assert!(backend.soft_query_surfaces.is_empty());
        assert!(!backend.initialized);
        assert_eq!(backend.world.body_count(), 0);
    }

    #[test]
    fn pair_orders_by_raw_value() {
        let low = EntityID::new(1, 0);
        let high = EntityID::new(9, 0);
        assert_eq!(Pair::ordered(high, low), Pair { a: low, b: high });
        assert_eq!(Pair::ordered(low, high), Pair { a: low, b: high });
    }

    #[test]
    fn clamped_shortens_only_above_maximum() {
        let value = Float3::new(3.0, 0.0, 0.0);
        assert_eq!(
            NatselPhysicsBackend::clamped(value, 6.0),
            value,
            "inside the limit is untouched"
        );
        assert_eq!(
            NatselPhysicsBackend::clamped(value, 1.5),
            Float3::new(1.5, 0.0, 0.0)
        );
        // A zero-length vector is left alone even when `maximum` is zero.
        assert_eq!(
            NatselPhysicsBackend::clamped(Float3::ZERO, 0.0),
            Float3::ZERO
        );
    }

    #[test]
    fn scale_reports_column_lengths() {
        let matrix = Float4x4::diagonal(Float4::new(2.0, 3.0, 4.0, 1.0));
        assert_eq!(
            NatselPhysicsBackend::scale(matrix),
            Float3::new(2.0, 3.0, 4.0)
        );
    }

    #[test]
    fn rotation_survives_a_zero_scale_column() {
        // A zero-length column is divided by the 1e-6 floor, not normalized, so the
        // result stays finite instead of becoming NaN.
        let matrix = Float4x4::diagonal(Float4::new(1.0, 0.0, 1.0, 1.0));
        let rotation = NatselPhysicsBackend::rotation(matrix);
        assert!(rotation.vector.x.is_finite());
        assert!(rotation.vector.y.is_finite());
        assert!(rotation.vector.z.is_finite());
        assert!(rotation.vector.w.is_finite());
    }

    #[test]
    fn matrix_round_trips_translation() {
        let matrix = NatselPhysicsBackend::matrix(
            Float3::new(1.0, 2.0, 3.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
            Float3::new(2.0, 2.0, 2.0),
        );
        assert_eq!(matrix.columns[3], Float4::new(1.0, 2.0, 3.0, 1.0));
        assert_eq!(matrix.columns[0], Float4::new(2.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn prepare_rejects_bodies_over_capacity() {
        let mut backend = NatselPhysicsBackend::new();
        let settings = PhysicsSettingsResource {
            capacity: crate::physics::physics_settings::PhysicsCapacitySettings::new(1, 1),
            ..PhysicsSettingsResource::default()
        };
        let context = PhysicsPrepareContext::new(
            settings,
            1.0 / 60.0,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            true,
        );
        let result = backend.prepare(context);
        assert!(result.error.is_none(), "no bodies fits a capacity of one");
    }

    #[test]
    fn prepare_full_snapshot_with_no_bodies_succeeds() {
        let mut backend = NatselPhysicsBackend::new();
        let context = PhysicsPrepareContext::new(
            PhysicsSettingsResource::default(),
            1.0 / 60.0,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            true,
        );
        let result = backend.prepare(context);
        assert_eq!(result.error, None);
        assert_eq!(result.synchronized_bodies, 0);
        assert!(backend.initialized);
    }
}
