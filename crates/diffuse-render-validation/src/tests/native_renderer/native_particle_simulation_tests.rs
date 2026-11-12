//! Ported from `Engine/Tests/NativeRendererTests/NativeParticleSimulationTests.swift`.

use std::sync::Arc;

use cove_graphics::rhi::{
    Buffer, CommandBuffer, Device, QueueClass, ShaderConstantValue, ShaderSpecializationConstant,
};
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::particles::particle_simulation_gpu_data::{
    GPUParticleSimulationEvent, GPUParticleSimulationMetadata, GPUParticleSimulationState,
    GPUParticleSimulationUniforms,
};
use diffuse_render::core::render_stats::GPUParticleSimulationEventSnapshot;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::particles::native_particle_simulation::{
    NativeParticleSimulation, NativeParticleSimulationKey, NativeParticleSimulationState,
};
use diffuse_render::native::targets::native_packet_validation::NativePacketValidation;
use diffuse_render::native::targets::native_shader_library::NativeShaderLibrary;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use diffuse_scene::particles::particle_types::{
    Particle, ParticleCollisionMode, ParticleForceMode, ParticleSimulationBackend,
    ParticleVectorFieldMode,
};
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderEnvironment, RenderParticleSimulationBatch, RenderScene,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::tests::native_renderer::support::{device, lock_serial};

fn make_batch(group: i64, count: usize) -> RenderParticleSimulationBatch {
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.max_particles = count as i64 + 3;
    settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
    settings.gpu_simulation.workgroup_size = group;
    let plan = ParticleEmitter::new(settings).gpu_simulation_plan();
    let particles = (0..count)
        .map(|index| {
            Particle::new(
                Float3::new(
                    (index % 13) as f32 * 0.03,
                    (index % 7) as f32 * 0.1 - 0.2,
                    (index % 11) as f32 * 0.02,
                ),
                Float3::new(0.2, -1.0, 0.3),
                (index % 5) as f32 * 0.1,
                if index % 17 == 0 { 0.1 } else { 8.0 },
                0.8,
                0.25,
                2.0,
                0.4,
                Float4::new(1.0, 0.5, 0.25, 0.8),
                (index % 7) as u8,
                index as u16,
                index as u16,
            )
        })
        .collect();
    RenderParticleSimulationBatch::new(
        None,
        plan,
        particles,
        Vec::new(),
        1.0,
        Float3::new(0.0, -2.0, 0.0),
        0.25,
        0.8,
        0.6,
        987_654_321,
        ParticleVectorFieldMode::Uniform,
        Float3::new(2.0, 0.0, 0.0),
        0.3,
        0.7,
        0.4,
        ParticleForceMode::Radial,
        Float3::new(-1.0, 0.0, 0.0),
        Float3::new(0.0, 1.0, 0.0),
        3.0,
        0.4,
        0.8,
        ParticleCollisionMode::LocalPlane,
        0.0,
        0.5,
        0.25,
        false,
        MATRIX_IDENTITY_FLOAT4X4,
        Float4::new(0.0, 0.0, 1.0, 1.0),
        1,
        1,
        1,
        0.0,
        diffuse_scene::particles::particle_types::ParticleTextureSheetPlaybackMode::Automatic,
        0,
        0,
        1.0,
        1.0,
        diffuse_scene::particles::particle_curve::ParticleCurve::Linear,
        Float4::splat(1.0),
        Float4::splat(1.0),
        diffuse_scene::particles::particle_curve::ParticleCurve::Linear,
        false,
        Vec::new(),
        diffuse_scene::particles::particle_types::ParticleBlendMode::Alpha,
        None,
        diffuse_scene::particles::particle_types::ParticleRenderAlignment::Billboard,
        0.0,
        8.0,
        diffuse_scene::particles::particle_types::ParticleSortMode::DistanceDescending,
        0,
        0,
        1.0,
        0.0,
        0,
        0.5,
        0.0,
    )
}

fn scene_with_batches(
    camera: RenderCamera,
    batches: Vec<RenderParticleSimulationBatch>,
) -> RenderScene {
    let mut scene = RenderScene::new(
        camera,
        Vec::new(),
        Vec::new(),
        RenderEnvironment::default(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        None,
    );
    scene.particle_simulation_batches = batches;
    scene
}

fn read_structs<T: Copy>(device: &Device, buffer: Buffer, count: usize) -> Vec<T> {
    if count == 0 {
        return Vec::new();
    }
    let stride = std::mem::size_of::<T>();
    let mut data = vec![0_u8; count * stride];
    device
        .read_buffer_data(buffer, 0, &mut data)
        .expect("read buffer");
    (0..count)
        .map(|index| {
            // SAFETY: the read stays inside `data`; `read_unaligned` accepts the
            // byte-aligned pointer.
            unsafe { std::ptr::read_unaligned(data.as_ptr().add(index * stride).cast::<T>()) }
        })
        .collect()
}

fn native_states(
    device: &Device,
    state: &NativeParticleSimulationState,
) -> Vec<GPUParticleSimulationState> {
    read_structs(device, state.state, state.capacity)
}

fn compare4(a: Float4, b: Float4) {
    for (left, right) in [(a.x, b.x), (a.y, b.y), (a.z, b.z), (a.w, b.w)] {
        assert!((left - right).abs() <= 0.0005, "{left} != {right}");
    }
}

fn event_order(
    a: &GPUParticleSimulationEvent,
    b: &GPUParticleSimulationEvent,
) -> std::cmp::Ordering {
    if a.params.y == b.params.y {
        a.params.x.cmp(&b.params.x)
    } else {
        a.params.y.cmp(&b.params.y)
    }
}

/// Simulation layouts, shader specialization and packet validation.
#[test]
fn simulation_layouts_and_packet_validation() {
    assert_eq!(std::mem::size_of::<GPUParticleSimulationState>(), 80);
    assert_eq!(std::mem::size_of::<GPUParticleSimulationUniforms>(), 272);
    assert_eq!(std::mem::size_of::<GPUParticleSimulationMetadata>(), 32);
    assert_eq!(std::mem::size_of::<GPUParticleSimulationEvent>(), 48);

    if std::env::var_os("COVE_RESOURCE_PATH").is_some() {
        for api in [
            cove_graphics::rhi::GraphicsApi::Metal,
            cove_graphics::rhi::GraphicsApi::Vulkan,
        ] {
            let artifact = NativeShaderLibrary::artifact(
                "particle_simulate",
                api,
                cove_graphics::rhi::ShaderStage::Compute,
            )
            .expect("simulate artifact");
            assert_eq!(artifact.interface.threadgroup_specialization.x, Some(0));
            let stride = |slot: u32| {
                artifact
                    .interface
                    .bindings
                    .iter()
                    .find(|binding| binding.slot == slot)
                    .map(|binding| binding.buffer.element_stride)
            };
            assert_eq!(stride(1), Some(80));
            assert_eq!(stride(2), Some(32));
            assert_eq!(stride(3), Some(48));
            let descriptor = artifact
                .module_descriptor(&[ShaderSpecializationConstant::new(
                    0,
                    ShaderConstantValue::Uint32(37),
                )])
                .expect("specialized module");
            assert_eq!(descriptor.threadgroup_size.x, 37);
        }
    }

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    let mut batch = make_batch(37, 3);
    batch.emitter_entity = Some(EntityID::from_raw_value(19));
    packet.scene.particle_simulation_batches = vec![batch.clone()];
    NativePacketValidation::validate(&packet).expect("valid packet");
    packet.scene.particle_simulation_batches = vec![batch.clone(), batch.clone()];
    assert!(NativePacketValidation::validate(&packet).is_err());
    packet.scene.particle_simulation_batches = vec![batch.clone()];
    packet.scene.particle_simulation_batches[0].force_strength = f32::NAN;
    assert!(NativePacketValidation::validate(&packet).is_err());
    packet.scene.particle_simulation_batches = vec![batch.clone()];
    packet.scene.particle_simulation_batches[0].particles[0].angular_velocity = f32::INFINITY;
    assert!(NativePacketValidation::validate(&packet).is_err());
    packet.scene.particle_simulation_batches = vec![batch.clone()];
    packet.scene.particle_simulation_batches[0].render_on_gpu = true;
    NativePacketValidation::validate(&packet).expect("GPU packet");
    packet.scene.particle_simulation_batches[0].trail_segments = i64::MAX;
    assert!(NativePacketValidation::validate(&packet).is_err());
    packet.scene.particle_simulation_batches = vec![batch];
    packet.scene.particle_simulation_batches[0]
        .plan
        .particle_capacity = (1 << 24) + 1;
    assert!(NativePacketValidation::validate(&packet).is_err());
}

/// Physics and events are workgroup-size invariant.
#[test]
fn physics_and_events_are_workgroup_invariant() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut simulation = NativeParticleSimulation::new(&device);
    let mut comparison = NativeParticleSimulation::new(&device);
    let scenarios = [
        (1_i64, 257_usize),
        (37, 257),
        (64, 131),
        (255, 257),
        (256, 513),
    ];
    for (scenario, (group, count)) in scenarios.into_iter().enumerate() {
        let mut batch = make_batch(group, count);
        if scenario % 2 == 1 {
            batch.vector_field_mode = ParticleVectorFieldMode::Curl;
            batch.force_mode = ParticleForceMode::Vortex;
            batch.collision_mode = ParticleCollisionMode::WorldPlane;
            let mut transform = MATRIX_IDENTITY_FLOAT4X4;
            transform.columns[0] = Float4::new(0.8, 0.4, 0.0, 0.0);
            transform.columns[1] = Float4::new(-0.3, 1.1, 0.0, 0.0);
            transform.columns[2].z = 1.3;
            transform.columns[3] = Float4::new(0.2, 0.1, -0.3, 1.0);
            batch.world_transform = transform;
            batch.collision_plane_y = 0.4;
        }
        if scenario == 4 {
            batch.force_radius = 0.0;
            batch.force_axis = Float3::ZERO;
            batch.vector_field_direction = Float3::ZERO;
        }
        let scene = scene_with_batches(
            RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO),
            vec![batch.clone()],
        );
        device.begin_frame().expect("frame");
        let mut commands = CommandBuffer::new();
        let update = simulation
            .prepare(&scene, 0.2, 1.7, &mut commands)
            .expect("prepare");
        let report = update.report;
        device
            .submit(&commands, QueueClass::Graphics, &[], &[], None)
            .expect("submit");
        simulation.commit(update);
        device.end_frame();
        let native = &simulation
            .entries
            .get(&NativeParticleSimulationKey::Anonymous(0))
            .expect("native entry")
            .state;
        let mut comparison_batch = batch;
        comparison_batch.plan.workgroup_size = 64;
        let comparison_scene = scene_with_batches(scene.camera, vec![comparison_batch]);
        device.begin_frame().expect("frame");
        let mut expected_commands = CommandBuffer::new();
        let expected_update = comparison
            .prepare(&comparison_scene, 0.2, 1.7, &mut expected_commands)
            .expect("prepare");
        device
            .submit(&expected_commands, QueueClass::Graphics, &[], &[], None)
            .expect("submit");
        comparison.commit(expected_update);
        device.end_frame();
        let expected_state = &comparison
            .entries
            .get(&NativeParticleSimulationKey::Anonymous(0))
            .expect("reference entry")
            .state;

        let raw_states = native_states(&device, native);
        for state in raw_states
            .iter()
            .filter(|state| state.position_lifetime.w == 0.0)
        {
            // SAFETY: the state is a live `#[repr(C)]` value; the byte range
            // covers exactly it.
            let bytes = unsafe {
                std::slice::from_raw_parts(
                    (state as *const GPUParticleSimulationState).cast::<u8>(),
                    std::mem::size_of::<GPUParticleSimulationState>(),
                )
            };
            assert!(bytes.iter().all(|byte| *byte == 0));
        }
        let mut actual: Vec<GPUParticleSimulationState> = raw_states
            .into_iter()
            .filter(|state| state.position_lifetime.w > 0.0)
            .collect();
        actual.sort_by_key(|state| state.params.z);
        let mut live: Vec<GPUParticleSimulationState> = native_states(&device, expected_state)
            .into_iter()
            .filter(|state| state.position_lifetime.w > 0.0)
            .collect();
        live.sort_by_key(|state| state.params.z);
        assert_eq!(actual.len(), live.len());
        for (a, b) in actual.iter().zip(live.iter()) {
            assert_eq!(a.params, b.params);
            compare4(a.position_lifetime, b.position_lifetime);
            compare4(a.velocity_age, b.velocity_age);
            compare4(a.size_rotation, b.size_rotation);
            compare4(a.color, b.color);
        }

        let snapshot = simulation
            .drain(1)
            .expect("drain")
            .into_iter()
            .next()
            .expect("snapshot");
        let metadata: GPUParticleSimulationMetadata =
            read_structs(&device, expected_state.metadata, 1)[0];
        assert_eq!(snapshot.alive_particle_count, metadata.alive_count as usize);
        assert_eq!(
            snapshot.expired_particle_count,
            metadata.expired_count as usize
        );
        assert_eq!(
            snapshot.collision_event_count,
            metadata.collision_count as usize
        );
        assert_eq!(snapshot.total_event_count, metadata.event_count as usize);
        assert_eq!(
            snapshot.compacted_particle_count,
            metadata.compacted_count as usize
        );
        let events: Vec<GPUParticleSimulationEvent> = read_structs(
            &device,
            expected_state.events,
            metadata.event_count as usize,
        );
        let mut ordered = events;
        ordered.sort_by(event_order);
        let mut records = snapshot.records.clone();
        records.sort_by(|a, b| {
            if a.source_index == b.source_index {
                a.trigger.raw_value().cmp(&b.trigger.raw_value())
            } else {
                a.source_index.cmp(&b.source_index)
            }
        });
        assert_eq!(records.len(), ordered.len());
        for (record, event) in records.iter().zip(ordered.iter()) {
            let decoded = event.record();
            assert_eq!(record.trigger, decoded.trigger);
            assert_eq!(record.source_index, decoded.source_index);
            assert_eq!(record.generation, decoded.generation);
            assert_eq!(record.appearance_index, decoded.appearance_index);
            compare4(
                Float4::new(
                    record.position.x,
                    record.position.y,
                    record.position.z,
                    record.lifetime,
                ),
                event.position_lifetime,
            );
            compare4(
                Float4::new(
                    record.velocity.x,
                    record.velocity.y,
                    record.velocity.z,
                    record.age,
                ),
                event.velocity_age,
            );
        }
        assert_eq!(snapshot.slot, 0);

        assert_eq!(report.particle_count, count as i64);
        assert_eq!(
            report.dispatch_workgroups,
            ((count as i64 + group - 1) / group)
        );
        let repeat = simulation
            .prepare(&scene, 0.2, 1.7, &mut CommandBuffer::new())
            .expect("repeat prepare");
        let _ = repeat;
        let _ = simulation.drain(1);
    }
}

/// Residency reset, failed recording and bounded snapshots.
#[test]
fn residency_reset_failed_recording_and_bounded_snapshots() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut simulation = NativeParticleSimulation::new(&device);
    let a = EntityID::from_raw_value(11);
    let b = EntityID::from_raw_value(22);
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.max_particles = 2;
    settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
    settings.gpu_simulation.workgroup_size = 37;
    let plan = ParticleEmitter::new(settings).gpu_simulation_plan();
    let particle = Particle::new(
        Float3::ZERO,
        Float3::new(1.0, 0.0, 0.0),
        0.0,
        100.0,
        1.0,
        0.0,
        0.0,
        1.0,
        Float4::splat(1.0),
        0,
        0,
        0,
    );
    let mut batch_a = make_batch(37, 1);
    batch_a.plan = plan.clone();
    batch_a.particles = vec![particle];
    batch_a.gravity = Float3::ZERO;
    batch_a.emitter_entity = Some(a);
    let mut batch_b = batch_a.clone();
    batch_b.emitter_entity = Some(b);
    batch_b.particles[0].position.x = 10.0;

    let camera = RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO);
    let frame = |simulation: &mut NativeParticleSimulation,
                 batches: Vec<RenderParticleSimulationBatch>,
                 delta_time: f32,
                 submit: bool| {
        device.begin_frame().expect("frame");
        let scene = scene_with_batches(camera, batches);
        let mut commands = CommandBuffer::new();
        let update = simulation
            .prepare(&scene, delta_time, 0.0, &mut commands)
            .expect("prepare");
        if submit {
            device
                .submit(&commands, QueueClass::Graphics, &[], &[], None)
                .expect("submit");
            simulation.commit(update);
        }
        device.end_frame();
    };

    frame(
        &mut simulation,
        vec![batch_a.clone(), batch_b.clone()],
        1.0,
        true,
    );
    let old_a = simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
        .expect("entry a")
        .state
        .state;
    frame(
        &mut simulation,
        vec![batch_b.clone(), batch_a.clone()],
        1.0,
        true,
    );
    assert_eq!(
        simulation
            .entries
            .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
            .expect("entry a")
            .state
            .state,
        old_a
    );
    let old_a_capacity = simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
        .expect("entry a")
        .state
        .capacity;
    let a_states = read_structs::<GPUParticleSimulationState>(&device, old_a, old_a_capacity);
    assert!((a_states[0].position_lifetime.x - 2.0).abs() <= 0.0001);
    let b_state = &simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(b.raw_value()))
        .expect("entry b")
        .state;
    let b_states =
        read_structs::<GPUParticleSimulationState>(&device, b_state.state, b_state.capacity);
    assert!((b_states[0].position_lifetime.x - 12.0).abs() <= 0.0001);
    assert!(simulation.drain(0).expect("drain").is_empty());
    let first: GPUParticleSimulationEventSnapshot = simulation
        .drain(1)
        .expect("drain")
        .into_iter()
        .next()
        .expect("first");
    assert_eq!(first.emitter_raw_value, Some(a.raw_value()));
    assert_eq!(first.slot, 0);
    assert_eq!(first.alive_particle_count, 1);
    let rest = simulation.drain(64).expect("drain");
    assert_eq!(
        rest.iter()
            .map(|snapshot| snapshot.emitter_raw_value)
            .collect::<Vec<_>>(),
        vec![
            Some(b.raw_value()),
            Some(b.raw_value()),
            Some(a.raw_value())
        ]
    );
    assert_eq!(
        rest.iter()
            .map(|snapshot| snapshot.slot)
            .collect::<Vec<_>>(),
        vec![1, 0, 1]
    );

    // Rejected recording does not execute physics or advance residency.
    frame(&mut simulation, vec![batch_a.clone()], 3.0, false);
    let a_states = read_structs::<GPUParticleSimulationState>(&device, old_a, old_a_capacity);
    assert!((a_states[0].position_lifetime.x - 2.0).abs() <= 0.0001);
    assert_eq!(simulation.entries.len(), 2);
    assert!(simulation.drain(64).expect("drain").is_empty());

    // A spawn can fill the resident spare slot; the next frame drops excess spawns.
    batch_a.particles.clear();
    batch_a.spawn_particles = vec![Particle::new(
        Float3::new(4.0, 0.0, 0.0),
        Float3::ZERO,
        0.0,
        100.0,
        1.0,
        0.0,
        0.0,
        1.0,
        Float4::splat(1.0),
        3,
        7,
        0,
    )];
    frame(&mut simulation, vec![batch_a.clone()], 0.0, true);
    let mut snapshot = simulation.drain(1).expect("drain").remove(0);
    assert_eq!(snapshot.gpu_spawned_particle_count, 1);
    assert_eq!(snapshot.compacted_particle_count, 2);
    frame(&mut simulation, vec![batch_a.clone()], 0.0, true);
    snapshot = simulation.drain(1).expect("drain").remove(0);
    assert_eq!(snapshot.gpu_spawned_particle_count, 0);
    assert_eq!(snapshot.gpu_dropped_spawn_count, 1);

    // Empty payload removes residency, and restoring it uses the supplied seed.
    frame(&mut simulation, Vec::new(), 1.0, true);
    assert!(simulation.entries.is_empty());
    batch_a.particles = vec![particle];
    batch_a.spawn_particles.clear();
    frame(&mut simulation, vec![batch_a.clone()], 1.0, true);
    let reset = simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
        .expect("entry a")
        .state
        .state;
    assert_ne!(reset, old_a);
    let reset_capacity = simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
        .expect("entry a")
        .state
        .capacity;
    let reset_states = read_structs::<GPUParticleSimulationState>(&device, reset, reset_capacity);
    assert!((reset_states[0].position_lifetime.x - 1.0).abs() <= 0.0001);

    batch_a.plan.workgroup_size = 255;
    frame(&mut simulation, vec![batch_a.clone()], 1.0, true);
    let regrouped = simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
        .expect("entry a")
        .state
        .state;
    assert_ne!(regrouped, reset);
    let regrouped_capacity = simulation
        .entries
        .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
        .expect("entry a")
        .state
        .capacity;
    let regrouped_states =
        read_structs::<GPUParticleSimulationState>(&device, regrouped, regrouped_capacity);
    assert!((regrouped_states[0].position_lifetime.x - 1.0).abs() <= 0.0001);

    batch_a.plan.particle_capacity = 5;
    frame(&mut simulation, vec![batch_a.clone()], 1.0, true);
    assert_eq!(
        simulation
            .entries
            .get(&NativeParticleSimulationKey::Emitter(a.raw_value()))
            .expect("entry a")
            .state
            .capacity,
        5
    );

    batch_a.emitter_entity = None;
    frame(&mut simulation, vec![batch_a.clone()], 1.0, true);
    frame(&mut simulation, vec![batch_a.clone()], 1.0, true);
    let anonymous = &simulation
        .entries
        .get(&NativeParticleSimulationKey::Anonymous(0))
        .expect("anonymous entry")
        .state;
    let anonymous_states =
        read_structs::<GPUParticleSimulationState>(&device, anonymous.state, anonymous.capacity);
    assert!((anonymous_states[0].position_lifetime.x - 1.0).abs() <= 0.0001);
    let _ = simulation.drain(64);
    for _ in 0..66 {
        frame(&mut simulation, vec![batch_a.clone()], 0.0, true);
    }
    assert_eq!(simulation.drain(usize::MAX).expect("drain").len(), 64);
    assert!(simulation.drain(usize::MAX).expect("drain").is_empty());

    device.wait_until_idle().expect("idle");
}

/// The renderer publishes simulation events and clears residency.
#[test]
fn renderer_publishes_simulation_events() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        diffuse_assets::asset_registry::AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    packet.scene.particle_simulation_batches = vec![make_batch(37, 3)];
    packet.delta_time = 0.2;
    renderer.render_checked(&packet).expect("first frame");
    let stats = renderer.current_frame_stats();
    assert_eq!(stats.gpu_particle_simulation_batch_count, 1);
    assert_eq!(stats.gpu_particle_simulation_particle_count, 3);
    assert_eq!(stats.gpu_particle_simulation_dispatch_workgroups, 1);
    assert_eq!(stats.gpu_particle_simulation_event_capacity, 12);
    assert_eq!(
        renderer
            .drain_gpu_particle_simulation_event_snapshots(1)
            .expect("drain")
            .len(),
        1
    );
    packet.scene.particle_simulation_batches[0].force_strength = f32::NAN;
    assert!(renderer.render_checked(&packet).is_err());
    packet.scene.particle_simulation_batches[0].force_strength = 0.4;
    packet.frame_index += 1;
    renderer.render_checked(&packet).expect("recovered frame");
    assert_eq!(
        renderer
            .drain_gpu_particle_simulation_event_snapshots(1)
            .expect("drain")
            .len(),
        1
    );
    packet.scene.particle_simulation_batches.clear();
    packet.frame_index += 1;
    renderer.render_checked(&packet).expect("empty batch frame");
    assert_eq!(
        renderer
            .current_frame_stats()
            .gpu_particle_simulation_batch_count,
        0
    );
    assert!(renderer.particle_simulation.entries.is_empty());

    device.wait_until_idle().expect("idle");
}
