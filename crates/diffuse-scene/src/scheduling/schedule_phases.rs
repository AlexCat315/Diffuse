//! The ten phases of one `RuntimeWorldSchedule` tick.
//!
//! Each function is one `case` of Swift's phase switch. The ordering constraints are
//! real and load-bearing:
//!
//! - transforms are propagated **before** scripts read world space and again after
//!   scripts write local transforms, because `WorldTransform` never derives itself
//!   from `LocalTransform`;
//! - `fixedPhysicsStep` refuses to advance when `prepare` failed, so a partially
//!   synchronized backend is never integrated;
//! - the sync cache is only committed when `prepare` succeeded — a failure leaves it
//!   empty so the next frame re-sends everything;
//! - `physicsWriteback` propagates transforms **before** refreshing the sync cache,
//!   otherwise the cache would record pre-writeback transforms.

use std::collections::BTreeMap;

use diffuse_kernel::job_system::JobSystem;

use crate::entity_id::EntityID;
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_scalability::ParticleScalabilityStateResource;
use crate::particles::particle_stats::{ParticleEmitterFrameStats, ParticleFrameStatsResource};
use crate::physics::backend::physics_backend::{PhysicsBackend, SharedPhysicsBackend};
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{PhysicsPrepareContext, PhysicsStepContext};
use crate::physics::backend::physics_query_scene::PhysicsQueryScene;
use crate::physics::character_controller::{
    CharacterCommandFrameResource, CharacterStateFrameResource,
};
use crate::physics::destruction::DestructionCommandFrameResource;
use crate::physics::destruction_runtime::{
    advance_destruction_pre_physics, apply_destruction_contacts,
};
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::physics_debug_frame::PhysicsDebugFrameResource;
use crate::physics::physics_events::{PhysicsContactEvent, PhysicsEventFrameResource};
use crate::physics::physics_frame_state::{
    PhysicsFrameBodyCounts, PhysicsFrameStateResource, PhysicsFrameSynchronization,
    PhysicsStateHashFrameResource, PhysicsStepClockResource,
};
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::spatial_queries::{
    SpatialIndexResource, build_spatial_index_resource,
};
use crate::physics::queries::trigger_detection::{
    TriggerEvent, TriggerEventKind, TriggerFrameResource,
};
use crate::physics::replay::physics_command_tape::{
    PhysicsCommandFrame, PhysicsCommandRecordingResource,
};
use crate::physics::replay::physics_replay_report::PhysicsCommandReplayControlResource;
use crate::physics::rigid_body::RigidBody;
use crate::physics::soft_bodies::soft_body::SoftBodyStateFrameResource;
use crate::physics::vehicles::vehicle_state::{
    VehicleCommandFrameResource, VehicleStateFrameResource,
};
use crate::runtime_world::RuntimeWorld;
use crate::scheduling::physics_collection::{
    PhysicsSyncCache, build_physics_read_view, collect_physics_bodies, collect_physics_characters,
    collect_physics_constraints, collect_physics_soft_bodies, collect_physics_vehicles,
    diff_physics_sync_events, merge_writebacks,
};
use crate::scheduling::physics_state_hash::physics_state_hash;
use crate::scheduling::ragdoll_bridge::{
    RagdollSimulatedBodiesResource, apply_ragdoll_animation_to_bodies,
    write_ragdoll_physics_to_animation,
};
use crate::scheduling::render_particles::particle_advance_options;
use crate::scheduling::schedule_commands::{RuntimeCommand, RuntimeCommandBuffer};
use crate::scheduling::schedule_debug_frame::build_physics_debug_frame;
use crate::scheduling::schedule_frame_context::RuntimeFrameContext;
use crate::scheduling::schedule_report::{
    RuntimeScheduleReport, ScheduleCommandReport, ScheduleJobReport, SchedulePhysicsReport,
};
use crate::scripting::{RuntimeScriptDriver, RuntimeScriptPhaseContext, SharedRuntimeScriptDriver};

/// Persistent state the schedule carries between frames.
#[derive(Clone)]
pub struct ScheduleState {
    pub physics_backend: SharedPhysicsBackend,
    pub explicit_physics_backend: Option<SharedPhysicsBackend>,
    pub script_driver: Option<SharedRuntimeScriptDriver>,
    pub physics_clock: PhysicsStepClockResource,
    pub physics_frame_state: PhysicsFrameStateResource,
    pub physics_contact_frame: crate::physics::physics_events::PhysicsContactFrameResource,
    pub physics_debug_frame: PhysicsDebugFrameResource,
    pub physics_event_frame: PhysicsEventFrameResource,
    pub character_state_frame: CharacterStateFrameResource,
    pub vehicle_state_frame: VehicleStateFrameResource,
    pub soft_body_state_frame: SoftBodyStateFrameResource,
    pub ragdoll_simulated_bodies: std::collections::BTreeSet<EntityID>,
    pub physics_sync_cache: PhysicsSyncCache,
    pub resolved_physics_backend_kind:
        crate::physics::backend::physics_backend_kind::PhysicsBackendKind,
    pub shared_physics_backend: SharedPhysicsBackend,
    pub shared_physics_backend_kind:
        crate::physics::backend::physics_backend_kind::PhysicsBackendKind,
    pub physics_query_scene: PhysicsQueryScene,
    pub job_system: JobSystem,
}

impl ScheduleState {
    /// A fresh schedule selecting the preferred backend, as Swift's `init()` does.
    pub fn new() -> Self {
        use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
        let kind = PhysicsBackendKind::preferred();
        let shared = SharedPhysicsBackend::new(kind.make_backend());
        let query_scene = PhysicsQueryScene::with_shared_backend(shared.clone());
        ScheduleState {
            physics_backend: SharedPhysicsBackend::new(Box::new(
                crate::physics::backend::null_physics_backend::NullPhysicsBackend::new(),
            )),
            explicit_physics_backend: None,
            script_driver: None,
            physics_clock: PhysicsStepClockResource::default(),
            physics_frame_state: PhysicsFrameStateResource::default(),
            physics_contact_frame: Default::default(),
            physics_debug_frame: PhysicsDebugFrameResource::default(),
            physics_event_frame: PhysicsEventFrameResource::default(),
            character_state_frame: CharacterStateFrameResource::default(),
            vehicle_state_frame: VehicleStateFrameResource::default(),
            soft_body_state_frame: SoftBodyStateFrameResource::default(),
            ragdoll_simulated_bodies: std::collections::BTreeSet::new(),
            physics_sync_cache: PhysicsSyncCache::new(),
            resolved_physics_backend_kind: PhysicsBackendKind::None,
            shared_physics_backend: shared,
            shared_physics_backend_kind: kind,
            physics_query_scene: query_scene,
            job_system: JobSystem::with_available_parallelism(),
        }
    }

    /// Whether `physics_backend` is still the schedule's shared instance.
    ///
    /// Physics-derived caches and the query scene are only valid while that instance
    /// survives, so this is an identity question, not a selection question.
    pub fn uses_shared_physics_backend(&self) -> bool {
        self.physics_backend
            .same_instance(&self.shared_physics_backend)
    }

    pub fn set_physics_backend(&mut self, backend: Box<dyn PhysicsBackend>) {
        let backend = SharedPhysicsBackend::new(backend);
        self.explicit_physics_backend = Some(backend.clone());
        self.physics_backend = backend;
        self.resolved_physics_backend_kind =
            crate::physics::backend::physics_backend_kind::PhysicsBackendKind::None;
        self.physics_frame_state.backend_identifier = self.physics_backend.identifier().to_string();
    }

    pub fn clear_physics_backend_override(&mut self) {
        self.explicit_physics_backend = None;
        self.resolved_physics_backend_kind =
            crate::physics::backend::physics_backend_kind::PhysicsBackendKind::None;
        self.physics_backend = SharedPhysicsBackend::new(Box::new(
            crate::physics::backend::null_physics_backend::NullPhysicsBackend::new(),
        ));
        self.physics_frame_state.backend_identifier = self.physics_backend.identifier().to_string();
    }

    pub fn set_script_driver(&mut self, driver: impl Into<SharedRuntimeScriptDriver>) {
        let driver = driver.into();
        if let Some(current) = self.script_driver.as_mut() {
            if current.same_instance(&driver) {
                return;
            }
            current.reset();
        }
        self.script_driver = Some(driver);
    }

    pub fn clear_script_driver(&mut self) {
        if let Some(driver) = self.script_driver.as_mut() {
            driver.reset();
        }
        self.script_driver = None;
    }
}

impl Default for ScheduleState {
    fn default() -> Self {
        Self::new()
    }
}

// MARK: - commandApply

/// Apply the drained command buffer.
pub fn apply_commands(
    commands: Vec<RuntimeCommand>,
    world: &mut RuntimeWorld,
    frame: &mut RuntimeFrameContext,
) {
    for command in commands {
        match command {
            RuntimeCommand::CreateEntity => frame.created_entities.push(world.create_entity()),
            RuntimeCommand::DestroyEntity(entity) => {
                if world.destroy_entity(entity) {
                    frame.destroyed_entities.push(entity);
                }
            }
            RuntimeCommand::SetParent { parent, child } => {
                world.set_parent(parent, child);
            }
            RuntimeCommand::SetLocalTransform { entity, transform } => {
                world.set_local_transform(transform, entity);
            }
        }
    }
}

// MARK: - inputAndPrePhysicsScripts

/// Run the driver's pre-physics callbacks, then destruction and ragdoll updates.
pub fn run_pre_physics_scripts(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    commands: &mut RuntimeCommandBuffer,
    frame: &mut RuntimeFrameContext,
    delta_time_seconds: f64,
) {
    let is_replaying = world
        .resource::<PhysicsCommandReplayControlResource>()
        .is_some_and(|control| control.is_replaying);

    if !is_replaying && let Some(driver) = state.script_driver.as_mut() {
        let mut context = RuntimeScriptPhaseContext::with_physics_query_scene(
            world,
            commands,
            delta_time_seconds,
            state.physics_query_scene.clone(),
        );
        driver.prepare_frame(&mut context);
        driver.run_pre_physics(&mut context);
    }

    if world.hierarchy_needs_propagation() {
        let report = world.propagate_transforms(&state.job_system);
        frame.jobs.record(
            &report,
            crate::scheduling::schedule_commands::RuntimeSystemPhase::InputAndPrePhysicsScripts,
        );
    }

    let mut destruction_events = frame.recording.destruction_events.clone();
    advance_destruction_pre_physics(world, delta_time_seconds, &mut destruction_events);
    frame.recording.destruction_events = destruction_events;

    let simulated = apply_ragdoll_animation_to_bodies(world);
    // Swift's `ragdollSimulatedBodies` is persistent schedule state; the bridge
    // reads it from the world, so publish the new set there as well.
    world.set_resource(RagdollSimulatedBodiesResource::new(simulated.clone()));
    state.ragdoll_simulated_bodies = simulated;

    if world.hierarchy_needs_propagation() {
        let report = world.propagate_transforms(&state.job_system);
        frame.jobs.record(
            &report,
            crate::scheduling::schedule_commands::RuntimeSystemPhase::InputAndPrePhysicsScripts,
        );
    }

    frame.physics_settings = world
        .resource::<crate::physics::physics_settings::PhysicsSettingsResource>()
        .unwrap_or_default();
    ensure_configured_physics_backend(state, frame.physics_settings.backend_kind);
}

/// Swap the backend when the settings select a different engine.
///
/// An explicit override always wins: the schedule must not replace a backend a caller
/// installed deliberately.
pub fn ensure_configured_physics_backend(
    state: &mut ScheduleState,
    kind: crate::physics::backend::physics_backend_kind::PhysicsBackendKind,
) {
    use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;

    if state.explicit_physics_backend.is_some() {
        return;
    }
    if state.resolved_physics_backend_kind == kind {
        return;
    }

    if state.uses_shared_physics_backend() {
        state.physics_query_scene.invalidate();
    }
    state.physics_backend.reset();

    if kind == PhysicsBackendKind::None {
        state.physics_backend = SharedPhysicsBackend::new(Box::new(
            crate::physics::backend::null_physics_backend::NullPhysicsBackend::new(),
        ));
    } else {
        if state.shared_physics_backend_kind != kind {
            state.shared_physics_backend = SharedPhysicsBackend::new(kind.make_backend());
            state.shared_physics_backend_kind = kind;
            state
                .physics_query_scene
                .replace_shared_backend(state.shared_physics_backend.clone());
        }
        state.physics_backend = state.shared_physics_backend.clone();
        if state.uses_shared_physics_backend() {
            state.physics_query_scene.invalidate();
        }
    }
    state.resolved_physics_backend_kind = kind;
}

// MARK: - fixedPhysicsPrepare

/// Collect descriptors, diff sync events and prepare the backend.
pub fn prepare_fixed_physics(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    frame: &mut RuntimeFrameContext,
    delta_time_seconds: f64,
) {
    if frame.physics_settings.simulation_mode == PhysicsSimulationMode::Off {
        reset_disabled_physics_resources(state, world);
        return;
    }

    let view = build_physics_read_view(world);
    let (bodies, body_report) = collect_physics_bodies(&view, &state.job_system);
    let (constraints, constraint_report) = collect_physics_constraints(&view, &state.job_system);
    frame.descriptors.bodies = bodies;
    frame.descriptors.constraints = constraints;
    frame.descriptors.characters = collect_physics_characters(&view);
    frame.descriptors.vehicles = collect_physics_vehicles(&view);
    frame.descriptors.soft_bodies = collect_physics_soft_bodies(&view);

    let active_soft_body_entities: std::collections::BTreeSet<EntityID> = frame
        .descriptors
        .soft_bodies
        .iter()
        .map(|descriptor| descriptor.entity)
        .collect();
    frame
        .results
        .soft_body_states
        .retain(|entity, _| active_soft_body_entities.contains(entity));

    record_physics_commands(state, world, frame);

    frame.jobs.record(
        &body_report,
        crate::scheduling::schedule_commands::RuntimeSystemPhase::FixedPhysicsPrepare,
    );
    frame.jobs.record(
        &constraint_report,
        crate::scheduling::schedule_commands::RuntimeSystemPhase::FixedPhysicsPrepare,
    );
    frame.metrics.body_count = frame.descriptors.bodies.len();
    frame.metrics.soft_body_count = frame.descriptors.soft_bodies.len();
    frame.metrics.constraint_count = frame.descriptors.constraints.len();

    let supported = state.physics_backend.capabilities();
    let all = PhysicsBackendCapabilities::all();
    if supported != all {
        let mut required = PhysicsBackendCapabilities::new(0);
        if !frame.descriptors.characters.is_empty() {
            required.insert(PhysicsBackendCapabilities::CHARACTERS);
        }
        if !frame.descriptors.vehicles.is_empty() {
            required.insert(PhysicsBackendCapabilities::VEHICLES);
        }
        if !frame.descriptors.soft_bodies.is_empty() {
            required.insert(PhysicsBackendCapabilities::SOFT_BODIES);
        }
        for descriptor in &frame.descriptors.constraints {
            match descriptor.constraint.configuration.kind() {
                crate::physics::joints::physics_joint_configuration::PhysicsJointKind::Cone => {
                    required.insert(PhysicsBackendCapabilities::CONE_JOINTS);
                }
                crate::physics::joints::physics_joint_configuration::PhysicsJointKind::SixDof => {
                    required.insert(PhysicsBackendCapabilities::SIX_DOF_JOINTS);
                }
                _ => {}
            }
        }
        let uses_cylinders = frame.descriptors.bodies.iter().any(|descriptor| {
            descriptor.collider.as_ref().is_some_and(|collider| {
                collider.shapes.iter().any(|instance| {
                    instance.shape.kind() == crate::physics::collider::ColliderShapeKind::Cylinder
                })
            })
        });
        if uses_cylinders {
            required.insert(PhysicsBackendCapabilities::CYLINDER_COLLIDERS);
        }
        let mut unsupported = required;
        unsupported.remove(supported);
        frame.metrics.unsupported_features = unsupported;
    }

    let (events, diff_report, cache) = diff_physics_sync_events(
        &frame.descriptors.bodies,
        &frame.descriptors.constraints,
        &frame.descriptors.vehicles,
        &frame.descriptors.soft_bodies,
        &state.physics_sync_cache,
        &state.job_system,
    );
    frame.results.sync_events = events;
    frame.jobs.record(
        &diff_report,
        crate::scheduling::schedule_commands::RuntimeSystemPhase::FixedPhysicsPrepare,
    );

    let prepare_context = PhysicsPrepareContext::new(
        frame.physics_settings,
        delta_time_seconds,
        frame.descriptors.bodies.clone(),
        frame.descriptors.constraints.clone(),
        frame.results.sync_events.clone(),
        frame.descriptors.characters.clone(),
        frame.descriptors.vehicles.clone(),
        frame.descriptors.soft_bodies.clone(),
        false,
    );
    let prepare_result = state.physics_backend.prepare(prepare_context);
    frame.metrics.synchronized_body_count += prepare_result.synchronized_bodies as usize;
    frame.metrics.synchronized_soft_body_count += prepare_result.synchronized_soft_bodies as usize;
    frame.metrics.synchronized_constraint_count += prepare_result.synchronized_constraints as usize;
    frame.metrics.error = prepare_result.error.clone();

    // Commit the cache only on success: a failed prepare means the backend does not
    // match these descriptors, so the next frame must re-send everything.
    state.physics_sync_cache = if prepare_result.error.is_none() {
        cache
    } else {
        PhysicsSyncCache::new()
    };

    if state.uses_shared_physics_backend() {
        state.physics_query_scene.adopt_synchronized_world(
            world,
            frame.descriptors.bodies.len(),
            frame.descriptors.constraints.len(),
        );
    }
}

/// Clear every physics-derived resource when simulation is switched off.
///
/// The world must keep reporting empty frames rather than stale simulation results.
pub fn reset_disabled_physics_resources(state: &mut ScheduleState, world: &mut RuntimeWorld) {
    if !state.uses_shared_physics_backend() {
        state.physics_backend.reset();
    }
    state.physics_sync_cache = PhysicsSyncCache::new();
    state.physics_clock = PhysicsStepClockResource::default();
    state.physics_frame_state = PhysicsFrameStateResource::default();
    state.physics_contact_frame = Default::default();
    state.physics_debug_frame = PhysicsDebugFrameResource::default();
    state.physics_event_frame = PhysicsEventFrameResource::default();
    state.character_state_frame = CharacterStateFrameResource::default();
    state.vehicle_state_frame = VehicleStateFrameResource::default();
    state.soft_body_state_frame = SoftBodyStateFrameResource::default();

    world.set_resource(state.physics_clock.clone());
    world.set_resource(state.physics_frame_state.clone());
    world.set_resource(state.physics_contact_frame.clone());
    world.set_resource(state.physics_debug_frame.clone());
    world.set_resource(state.physics_event_frame.clone());
    world.set_resource(state.character_state_frame.clone());
    world.set_resource(state.vehicle_state_frame.clone());
    world.set_resource(state.soft_body_state_frame.clone());
}

/// Capture the frame's physics commands when recording is on and replay is off.
fn record_physics_commands(
    _state: &mut ScheduleState,
    world: &RuntimeWorld,
    frame: &mut RuntimeFrameContext,
) {
    let is_recording = world
        .resource::<PhysicsCommandRecordingResource>()
        .is_some_and(|recording| recording.is_recording);
    let is_replaying = world
        .resource::<PhysicsCommandReplayControlResource>()
        .is_some_and(|control| control.is_replaying);
    if !is_recording || is_replaying {
        return;
    }

    frame.recording.body_commands = frame
        .descriptors
        .bodies
        .iter()
        .filter_map(|descriptor| {
            let body = descriptor.rigid_body.as_ref()?;
            let has_command = body.accumulated_force
                != diffuse_math::simd::simd_compat::Float3::ZERO
                || body.accumulated_torque != diffuse_math::simd::simd_compat::Float3::ZERO
                || body.accumulated_linear_impulse != diffuse_math::simd::simd_compat::Float3::ZERO
                || body.accumulated_angular_impulse
                    != diffuse_math::simd::simd_compat::Float3::ZERO;
            if !has_command {
                return None;
            }
            Some(
                crate::physics::replay::physics_command_tape::PhysicsRecordedBodyCommand {
                    entity: descriptor.entity,
                    force: body.accumulated_force,
                    torque: body.accumulated_torque,
                    linear_impulse: body.accumulated_linear_impulse,
                    angular_impulse: body.accumulated_angular_impulse,
                    wake: !body.is_sleeping,
                },
            )
        })
        .collect();

    let character_commands = world
        .resource::<CharacterCommandFrameResource>()
        .map(|resource| resource.commands.clone())
        .unwrap_or_default();
    frame.recording.character_commands = character_commands
        .into_iter()
        .map(|(entity, command)| {
            crate::physics::replay::physics_command_tape::PhysicsRecordedCharacterCommand {
                entity,
                command,
            }
        })
        .collect();
    frame
        .recording
        .character_commands
        .sort_by_key(|command| command.entity.raw_value());

    let vehicle_commands = world
        .resource::<VehicleCommandFrameResource>()
        .map(|resource| resource.commands.clone())
        .unwrap_or_default();
    frame.recording.vehicle_commands = vehicle_commands
        .into_iter()
        .map(|(entity, command)| {
            crate::physics::replay::physics_command_tape::PhysicsRecordedVehicleCommand {
                entity,
                command,
            }
        })
        .collect();
    frame
        .recording
        .vehicle_commands
        .sort_by_key(|command| command.entity.raw_value());

    frame.recording.destruction_commands = world
        .resource::<DestructionCommandFrameResource>()
        .map(|resource| resource.commands.clone())
        .unwrap_or_default();
}

// MARK: - fixedPhysicsStep

/// Advance the fixed-step clock, running at most `max_substeps_per_frame` substeps.
pub fn step_fixed_physics(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    frame: &mut RuntimeFrameContext,
) {
    if frame.physics_settings.simulation_mode == PhysicsSimulationMode::Off {
        return;
    }
    // A failed synchronization means the backend does not match the descriptors.
    // Preserve the original error and never advance a partially synchronized world.
    if frame.metrics.error.is_some() {
        return;
    }

    state.physics_clock.accumulated_seconds += frame.delta_time_seconds;
    state.physics_clock.last_step_count = 0;
    state.physics_clock.last_stepped_seconds = 0.0;
    state.physics_clock.last_dropped_step_count = 0;

    let fixed_step = frame
        .physics_settings
        .fixed_time_step_seconds
        .max(0.000_001);
    let max_substeps = frame.physics_settings.max_substeps_per_frame.max(0);
    let mut substep_index: i64 = 0;

    // The epsilon makes an exactly-divisible accumulator step instead of stalling
    // one frame behind due to float rounding.
    while state.physics_clock.accumulated_seconds + 0.000_000_1 >= fixed_step
        && substep_index < max_substeps
    {
        let character_commands = world
            .resource::<CharacterCommandFrameResource>()
            .map(|resource| resource.commands.clone())
            .unwrap_or_default();
        let vehicle_commands = world
            .resource::<VehicleCommandFrameResource>()
            .map(|resource| resource.commands.clone())
            .unwrap_or_default();

        let step_context = PhysicsStepContext::new(
            frame.physics_settings,
            fixed_step,
            substep_index,
            frame.descriptors.bodies.clone(),
            frame.descriptors.constraints.clone(),
            frame.descriptors.characters.clone(),
            character_commands,
            frame.descriptors.vehicles.clone(),
            vehicle_commands,
            frame.descriptors.soft_bodies.clone(),
        );
        let step_result = state.physics_backend.step(step_context);

        if let Some(error) = step_result.error.clone() {
            frame.metrics.error = Some(error);
        }
        state.physics_clock.accumulated_seconds -= fixed_step;
        state.physics_clock.simulated_steps += 1;
        state.physics_clock.last_step_count += 1;
        state.physics_clock.last_stepped_seconds += fixed_step;
        frame.metrics.step_count += 1;
        frame.metrics.contact_count += step_result.contact_count as usize;
        frame
            .results
            .contact_events
            .extend(step_result.contact_events.iter().cloned());
        frame
            .results
            .joint_break_events
            .extend(step_result.joint_break_events.iter().cloned());

        // A broken joint is disabled immediately so the next substep does not
        // re-solve a constraint the solver already gave up on.
        for event in &step_result.joint_break_events {
            world.update_component::<Constraint>(event.joint_entity, |joint| {
                joint.is_enabled = false;
            });
        }

        frame.results.writebacks = merge_writebacks(
            frame.results.writebacks.clone(),
            step_result.writebacks.clone(),
        );
        for character in &step_result.character_states {
            frame
                .results
                .character_states
                .insert(character.entity, *character);
        }
        for vehicle in &step_result.vehicle_states {
            frame
                .results
                .vehicle_states
                .insert(vehicle.entity, vehicle.clone());
        }
        for soft_body in &step_result.soft_body_states {
            frame
                .results
                .soft_body_states
                .insert(soft_body.entity, soft_body.clone());
        }
        substep_index += 1;
    }

    // Anything left over beyond the substep budget is dropped, not carried: carrying
    // it would make a slow frame produce a burst of steps later.
    if substep_index >= max_substeps
        && state.physics_clock.accumulated_seconds + 0.000_000_1 >= fixed_step
    {
        let dropped = (state.physics_clock.accumulated_seconds / fixed_step) as i64;
        state.physics_clock.accumulated_seconds %= fixed_step;
        state.physics_clock.dropped_steps += dropped;
        state.physics_clock.last_dropped_step_count = dropped;
    }
}

// MARK: - physicsWriteback

/// Apply simulation results back into the world.
pub fn write_back_physics(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    frame: &mut RuntimeFrameContext,
) {
    if frame.physics_settings.simulation_mode == PhysicsSimulationMode::Off {
        return;
    }

    for writeback in &frame.results.writebacks {
        if world.apply_physics_writeback(writeback) {
            frame.metrics.writeback_count += 1;
        }
    }

    let mut characters: Vec<_> = frame.results.character_states.values().cloned().collect();
    characters.sort_by_key(|character| character.entity.raw_value());
    for character in characters {
        let Some(mut transform) = world.world_transform(character.entity) else {
            continue;
        };
        transform.matrix.set_column(
            3,
            diffuse_math::simd::simd_compat::Float4::new(
                character.position.x,
                character.position.y,
                character.position.z,
                1.0,
            ),
        );
        world.apply_physics_writeback(
            &crate::physics::backend::physics_backend_context::PhysicsBodyWriteback {
                world_transform: Some(transform),
                ..crate::physics::backend::physics_backend_context::PhysicsBodyWriteback::new(
                    character.entity,
                )
            },
        );
    }

    if frame.metrics.step_count > 0 {
        let entities: Vec<EntityID> = frame
            .descriptors
            .bodies
            .iter()
            .map(|descriptor| descriptor.entity)
            .collect();
        world.clear_physics_accumulators(&entities);
    }

    if frame.metrics.writeback_count > 0 {
        let report = world.propagate_transforms(&state.job_system);
        frame.jobs.record(
            &report,
            crate::scheduling::schedule_commands::RuntimeSystemPhase::PhysicsWriteback,
        );
    }

    if frame.metrics.step_count > 0 {
        refresh_physics_sync_cache_after_writeback(state, world, &frame.descriptors.bodies);
    }

    let soft_vertex_count: usize = frame
        .results
        .soft_body_states
        .values()
        .map(|state| state.positions.len())
        .sum();
    let active_body_count = frame
        .descriptors
        .bodies
        .iter()
        .filter(|descriptor| {
            world
                .component::<RigidBody>(descriptor.entity)
                .is_some_and(|body| {
                    body.motion_type != crate::physics::rigid_body::RigidBodyMotionType::Static
                        && !body.is_sleeping
                })
        })
        .count();
    let active_soft_body_count = frame
        .results
        .soft_body_states
        .values()
        .filter(|state| !state.is_sleeping)
        .count();

    state.physics_frame_state = PhysicsFrameStateResource {
        backend_identifier: state.physics_backend.identifier().to_string(),
        counts: PhysicsFrameBodyCounts {
            total: frame.metrics.body_count as i64,
            soft: frame.metrics.soft_body_count as i64,
            soft_vertices: soft_vertex_count as i64,
            constraints: frame.metrics.constraint_count as i64,
            contacts: frame.metrics.contact_count as i64,
            writebacks: frame.metrics.writeback_count as i64,
        },
        synchronization: PhysicsFrameSynchronization {
            bodies: frame.metrics.synchronized_body_count as i64,
            soft_bodies: frame.metrics.synchronized_soft_body_count as i64,
            constraints: frame.metrics.synchronized_constraint_count as i64,
            nanoseconds: frame.metrics.synchronization_nanoseconds,
        },
        simulated_steps: frame.metrics.step_count as i64,
        simulated_seconds: state.physics_clock.last_stepped_seconds,
        active_body_count: active_body_count as i64,
        active_soft_body_count: active_soft_body_count as i64,
        dropped_step_count: state.physics_clock.last_dropped_step_count,
        step_nanoseconds: frame.metrics.step_nanoseconds,
        last_error: frame.metrics.error.clone(),
        unsupported_features: frame.metrics.unsupported_features,
    };
    state.physics_contact_frame =
        crate::physics::physics_events::PhysicsContactFrameResource::from_events(
            &frame.results.contact_events,
        );
    state.character_state_frame =
        CharacterStateFrameResource::new(frame.results.character_states.clone());
    state.vehicle_state_frame =
        VehicleStateFrameResource::new(frame.results.vehicle_states.clone());
    state.soft_body_state_frame =
        SoftBodyStateFrameResource::new(frame.results.soft_body_states.clone());

    world.set_resource(state.physics_clock.clone());
    world.set_resource(state.physics_frame_state.clone());
    world.set_resource(state.character_state_frame.clone());
    world.set_resource(state.vehicle_state_frame.clone());
    world.set_resource(state.soft_body_state_frame.clone());

    let state_hash_frame = PhysicsStateHashFrameResource {
        simulated_step: state.physics_clock.simulated_steps,
        hash: physics_state_hash(world),
    };
    world.set_resource(state_hash_frame.clone());
    append_physics_command_frame(state, world, frame, state_hash_frame);
    world.set_resource(state.physics_contact_frame.clone());

    if state.uses_shared_physics_backend() {
        state.physics_query_scene.adopt_synchronized_world(
            world,
            frame.descriptors.bodies.len(),
            frame.descriptors.constraints.len(),
        );
    }
}

/// Refresh cached descriptors with post-writeback transforms.
///
/// Must run **after** transform propagation: refreshing before would record the
/// pre-writeback pose and make the next frame think nothing moved.
fn refresh_physics_sync_cache_after_writeback(
    state: &mut ScheduleState,
    world: &RuntimeWorld,
    active_bodies: &[crate::physics::backend::physics_descriptors::PhysicsBodyDescriptor],
) {
    let entities = world.entities();
    let local_transforms = world.local_transform_snapshot_matching(&entities);
    let world_transforms = world.world_transform_snapshot_matching(&entities);
    let rigid_bodies = world.component_snapshot::<RigidBody>();
    let colliders = world.component_snapshot::<crate::physics::collider::Collider>();

    for descriptor in active_bodies {
        let Some(cached) = state.physics_sync_cache.bodies.get_mut(&descriptor.entity) else {
            continue;
        };
        let (Some(local), Some(world_transform)) = (
            local_transforms.get(&descriptor.entity),
            world_transforms.get(&descriptor.entity),
        ) else {
            continue;
        };
        cached.local_transform = *local;
        cached.world_transform = *world_transform;
        cached.rigid_body = rigid_bodies.get(&descriptor.entity).cloned();
        cached.collider = colliders.get(&descriptor.entity).cloned();
    }
}

/// Append this frame to the recording tape, when one is active.
fn append_physics_command_frame(
    _state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    frame: &RuntimeFrameContext,
    state_hash_frame: PhysicsStateHashFrameResource,
) {
    let Some(mut recording) = world.resource::<PhysicsCommandRecordingResource>() else {
        return;
    };
    if !recording.is_recording {
        return;
    }
    if world
        .resource::<PhysicsCommandReplayControlResource>()
        .is_some_and(|control| control.is_replaying)
    {
        return;
    }

    let stepped_this_frame = frame.metrics.step_count > 0;
    if (recording.frames.len() as i64) < recording.max_frames {
        recording.frames.push(PhysicsCommandFrame {
            delta_time_seconds: frame.delta_time_seconds,
            settings: frame.physics_settings,
            body_commands: if stepped_this_frame {
                frame.recording.body_commands.clone()
            } else {
                Vec::new()
            },
            character_commands: if stepped_this_frame {
                frame.recording.character_commands.clone()
            } else {
                Vec::new()
            },
            vehicle_commands: if stepped_this_frame {
                frame.recording.vehicle_commands.clone()
            } else {
                Vec::new()
            },
            destruction_commands: frame.recording.destruction_commands.clone(),
            expected_simulated_step: state_hash_frame.simulated_step,
            expected_state_hash: state_hash_frame.hash,
        });
    }
    if (recording.frames.len() as i64) >= recording.max_frames {
        recording.is_recording = false;
    }
    world.set_resource(recording);
}

// MARK: - triggerDetection

/// Split contact events into contacts, triggers and destruction contacts.
pub fn detect_triggers(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    frame: &mut RuntimeFrameContext,
) {
    if frame.physics_settings.simulation_mode == PhysicsSimulationMode::Off {
        // An edit/query-only world never steps the backend, so it cannot receive
        // contact callbacks. Preserve trigger previews through the query scene.
        // Synchronize first: the event budget must cover the bodies of *this*
        // frame. Reading the count before the sync left the first frame with a
        // zero budget, so an overlap that existed from the start never reported
        // its enter event.
        let mut backend = state.physics_query_scene.synchronize(world);
        let body_count = state.physics_query_scene.stats().body_count;
        let max_events = body_count * body_count.max(1) * 3;
        let trigger_frame = backend.detect_trigger_frame(max_events);
        state.physics_event_frame = PhysicsEventFrameResource::new(
            Vec::new(),
            trigger_frame
                .enters
                .iter()
                .cloned()
                .chain(trigger_frame.active.iter().cloned())
                .chain(trigger_frame.exits.iter().cloned())
                .collect(),
            Vec::new(),
            false,
        );
        world.set_resource(trigger_frame);
        world.set_resource(state.physics_event_frame.clone());
        return;
    }

    let triggers: BTreeMap<EntityID, bool> = frame
        .descriptors
        .bodies
        .iter()
        .filter_map(|body| {
            body.collider
                .as_ref()
                .map(|collider| (body.entity, collider.is_trigger))
        })
        .collect();

    let mut contact_events: Vec<PhysicsContactEvent> = Vec::new();
    let mut trigger_events: Vec<TriggerEvent> = Vec::new();

    for event in &frame.results.contact_events {
        let a_is_trigger = triggers.get(&event.entity_a).copied().unwrap_or(false);
        let b_is_trigger = triggers.get(&event.entity_b).copied().unwrap_or(false);
        if !a_is_trigger && !b_is_trigger {
            contact_events.push(*event);
            continue;
        }

        // When both sides are triggers the lower entity is designated the trigger, so
        // the pair is reported exactly once.
        let (trigger, other) = if a_is_trigger && !b_is_trigger {
            (event.entity_a, event.entity_b)
        } else if b_is_trigger && !a_is_trigger {
            (event.entity_b, event.entity_a)
        } else if event.entity_a.raw_value() <= event.entity_b.raw_value() {
            (event.entity_a, event.entity_b)
        } else {
            (event.entity_b, event.entity_a)
        };

        let kind = match event.kind {
            crate::physics::physics_events::PhysicsContactEventKind::Began => {
                TriggerEventKind::Enter
            }
            crate::physics::physics_events::PhysicsContactEventKind::Stayed => {
                TriggerEventKind::Active
            }
            crate::physics::physics_events::PhysicsContactEventKind::Ended => {
                TriggerEventKind::Exit
            }
        };
        trigger_events.push(TriggerEvent::new(trigger, other, kind));
    }

    contact_events.sort_by_key(|event| {
        (
            event.entity_a.raw_value(),
            event.entity_b.raw_value(),
            event.sub_shape_id_a,
            event.sub_shape_id_b,
        )
    });
    trigger_events.sort_by_key(|event| {
        (
            event.trigger_entity.raw_value(),
            event.other_entity.raw_value(),
            event.kind.raw_value(),
        )
    });

    let enters: Vec<TriggerEvent> = trigger_events
        .iter()
        .filter(|event| event.kind == TriggerEventKind::Enter)
        .cloned()
        .collect();
    let exits: Vec<TriggerEvent> = trigger_events
        .iter()
        .filter(|event| event.kind == TriggerEventKind::Exit)
        .cloned()
        .collect();
    // `active` includes enters and stays, matching Swift (everything except exits).
    let active: Vec<TriggerEvent> = trigger_events
        .iter()
        .filter(|event| event.kind != TriggerEventKind::Exit)
        .cloned()
        .collect();

    let trigger_frame = TriggerFrameResource::new(enters, exits, active);
    state.physics_contact_frame =
        crate::physics::physics_events::PhysicsContactFrameResource::from_events(&contact_events);
    state.physics_event_frame = PhysicsEventFrameResource::new(
        contact_events.clone(),
        trigger_events,
        frame.results.joint_break_events.clone(),
        false,
    );
    world.set_resource(trigger_frame);
    world.set_resource(state.physics_contact_frame.clone());
    world.set_resource(state.physics_event_frame.clone());

    let mut destruction_events = frame.recording.destruction_events.clone();
    apply_destruction_contacts(&contact_events, world, &mut destruction_events);
    frame.recording.destruction_events = destruction_events;
}

// MARK: - postPhysicsScripts

/// Run the driver's post-physics callback, then ragdoll and particle updates.
pub fn run_post_physics_scripts(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    commands: &mut RuntimeCommandBuffer,
    frame: &mut RuntimeFrameContext,
    delta_time_seconds: f64,
) {
    if let Some(driver) = state.script_driver.as_mut() {
        let mut context = RuntimeScriptPhaseContext::with_physics_query_scene(
            world,
            commands,
            delta_time_seconds,
            state.physics_query_scene.clone(),
        );
        driver.run_post_physics(&mut context);
    }

    if world.hierarchy_needs_propagation() {
        let report = world.propagate_transforms(&state.job_system);
        frame.jobs.record(
            &report,
            crate::scheduling::schedule_commands::RuntimeSystemPhase::PostPhysicsScripts,
        );
    }

    write_ragdoll_physics_to_animation(world);
    advance_particle_emitters(world, delta_time_seconds);
}

/// Advance every `ParticleEmitter` and publish this frame's stats.
fn advance_particle_emitters(world: &mut RuntimeWorld, delta_time_seconds: f64) {
    // Swift's `guard deltaTime > 0 else`: a NaN delta must also take the empty path.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    let advancing = delta_time_seconds > 0.0;
    if !advancing {
        world.set_derived_resource(ParticleFrameStatsResource::empty());
        world.set_derived_resource(ParticleScalabilityStateResource::default());
        return;
    }

    let particle_options = particle_advance_options(world);
    let particle_entities = world.entities_with::<ParticleEmitter>();
    let world_transforms = world.world_transform_snapshot_matching(&particle_entities);
    let mut particle_stats: Vec<ParticleEmitterFrameStats> =
        Vec::with_capacity(particle_entities.len());
    let mut particle_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats> = BTreeMap::new();

    world.update_components::<ParticleEmitter>(|entity, emitter| {
        emitter.advance(
            delta_time_seconds,
            world_transforms
                .get(&entity)
                .map(|transform| transform.matrix),
            &particle_options,
        );
        let stats = emitter.last_frame_stats();
        particle_stats.push(stats);
        particle_stats_by_entity.insert(entity.raw_value(), stats);
    });

    world.set_derived_resource(ParticleFrameStatsResource::new(
        delta_time_seconds as f32,
        particle_stats,
        particle_stats_by_entity,
        0,
        0,
        0,
        0,
        0,
        0,
    ));
}

// MARK: - spatialIndexUpdate

/// Rebuild the spatial index and the debug frame.
pub fn update_spatial_index(
    state: &mut ScheduleState,
    world: &mut RuntimeWorld,
    frame: &mut RuntimeFrameContext,
) {
    let (index, report) = build_spatial_index_resource(world, &state.job_system);
    world.set_resource(index.clone());
    state.physics_debug_frame = build_physics_debug_frame(
        world,
        &index,
        &frame.results.contact_events,
        &state.character_state_frame,
    );
    world.set_resource(state.physics_debug_frame.clone());
    frame.jobs.record(
        &report,
        crate::scheduling::schedule_commands::RuntimeSystemPhase::SpatialIndexUpdate,
    );
}

/// Read the current spatial index for a caller that needs it outside a phase.
pub fn current_spatial_index(world: &RuntimeWorld) -> SpatialIndexResource {
    world.resource::<SpatialIndexResource>().unwrap_or_default()
}

/// Report assembly for the end of a tick.
pub fn build_schedule_report(
    state: &ScheduleState,
    world: &RuntimeWorld,
    frame: &RuntimeFrameContext,
    phase_nanoseconds: BTreeMap<crate::scheduling::schedule_commands::RuntimeSystemPhase, u64>,
) -> RuntimeScheduleReport {
    use crate::scheduling::schedule_commands::RuntimeSystemPhase;

    let soft_vertex_count: usize = state
        .soft_body_state_frame
        .states
        .values()
        .map(|state| state.positions.len())
        .sum();

    RuntimeScheduleReport {
        phases: RuntimeSystemPhase::ALL.to_vec(),
        commands: ScheduleCommandReport {
            applied_count: frame.commands_applied_count,
            created_entities: frame.created_entities.clone(),
            destroyed_entities: frame.destroyed_entities.clone(),
        },
        physics: SchedulePhysicsReport {
            step_count: frame.metrics.step_count,
            writeback_count: frame.metrics.writeback_count,
            body_count: frame.metrics.body_count,
            soft_body_count: frame.metrics.soft_body_count,
            soft_body_vertex_count: soft_vertex_count,
            constraint_count: frame.metrics.constraint_count,
            contact_count: frame.metrics.contact_count,
            backend_identifier: state.physics_backend.identifier().to_string(),
            synchronization_nanoseconds: frame.metrics.synchronization_nanoseconds,
            step_nanoseconds: frame.metrics.step_nanoseconds,
            dropped_step_count: state.physics_clock.last_dropped_step_count as usize,
            error: frame.metrics.error.clone(),
        },
        jobs: ScheduleJobReport {
            scheduled_count: frame.jobs.scheduled_job_count,
            worker_count: state.job_system.worker_count,
            parallel_phases: RuntimeSystemPhase::ALL
                .iter()
                .copied()
                .filter(|phase| frame.jobs.parallel_phases.contains(phase))
                .collect(),
            phase_job_counts: frame.jobs.phase_job_counts.clone(),
        },
        revision: world.revision(),
        phase_nanoseconds,
    }
}
