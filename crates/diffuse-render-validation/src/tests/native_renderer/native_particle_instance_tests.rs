//! Ported from `Engine/Tests/NativeRendererTests/NativeParticleInstanceTests.swift`.

use std::sync::Arc;

use cove_graphics::rhi::{Buffer, CommandBuffer, Device, QueueClass};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::particles::particle_gpu_data::GPUParticleInstance;
use diffuse_render::core::particles::particle_instance_gpu_data::{
    GPUParticleAppearance, GPUParticleAppearanceData, GPUParticleCurveKeyframe,
    GPUParticleSimulationInstanceUniforms, GPUParticleSortBitonicUniforms, GPUParticleSortItem,
    GPUParticleSortPlan, GPUParticleSortPrepareUniforms,
};
use diffuse_render::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::particles::native_particle_instances::{
    NativeParticleInstanceKernels, NativeParticleSortBuffer, NativeParticleSourceBuffer,
};
use diffuse_render::native::particles::native_particle_simulation::{
    NativeParticleSimulationKey, NativeParticleSimulationState,
};
use diffuse_render::{DebugViewMode, RenderDrawableSize, RenderPassKind, RenderSettings};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use diffuse_scene::particles::particle_curve::{ParticleCurve, ParticleCurveKeyframe};
use diffuse_scene::particles::particle_types::{
    Particle, ParticleBlendMode, ParticleCollisionMode, ParticleForceMode, ParticleRenderAlignment,
    ParticleSimulationBackend, ParticleSortMode, ParticleTextureSheetPlaybackMode,
    ParticleVectorFieldMode,
};
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderParticle, RenderParticleAppearance, RenderParticleSimulationBatch,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::{device, lock_serial};

fn make_batch(group: i64, scenario: i64) -> RenderParticleSimulationBatch {
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.max_particles = 137;
    settings.gpu_simulation.simulation_backend = ParticleSimulationBackend::GpuRequired;
    settings.gpu_simulation.workgroup_size = group;
    let plan = ParticleEmitter::new(settings).gpu_simulation_plan();
    let particles: Vec<Particle> = (0..131)
        .map(|index: i64| {
            let position = Float3::new(
                (index % 13) as f32 * 0.08 - 0.4,
                (index % 7) as f32 * 0.06,
                (index % 11) as f32 * 0.04,
            );
            let velocity = if index % 5 == 0 {
                Float3::ZERO
            } else {
                Float3::new(0.2, 0.1, -0.3)
            };
            let lifetime = if index % 19 == 0 {
                0.0
            } else if index % 23 == 0 {
                0.2
            } else {
                3.0
            };
            let color = Float4::new(0.9, 0.3 + (index % 3) as f32 * 0.2, 0.4, 0.7);
            Particle::new(
                position,
                velocity,
                (index % 9) as f32 * 0.13,
                lifetime,
                0.7,
                index as f32 * 0.05,
                0.6,
                0.12,
                color,
                0,
                (index % 5) as u16,
                (index * 7) as u16,
            )
        })
        .collect();
    let mut batch = RenderParticleSimulationBatch::new(
        None,
        plan,
        particles,
        Vec::new(),
        1.0,
        Float3::ZERO,
        0.0,
        1.0,
        0.0,
        0,
        ParticleVectorFieldMode::None,
        Float3::new(0.0, 1.0, 0.0),
        0.0,
        1.0,
        0.0,
        ParticleForceMode::None,
        Float3::ZERO,
        Float3::new(0.0, 1.0, 0.0),
        0.0,
        0.0,
        1.0,
        ParticleCollisionMode::None,
        0.0,
        0.5,
        0.0,
        true,
        MATRIX_IDENTITY_FLOAT4X4,
        Float4::new(0.0, 0.0, 1.0, 1.0),
        1,
        1,
        1,
        0.0,
        ParticleTextureSheetPlaybackMode::Automatic,
        0,
        0,
        1.0,
        1.0,
        ParticleCurve::Linear,
        Float4::splat(1.0),
        Float4::splat(1.0),
        ParticleCurve::Linear,
        false,
        Vec::new(),
        ParticleBlendMode::Alpha,
        None,
        ParticleRenderAlignment::Billboard,
        0.0,
        8.0,
        ParticleSortMode::DistanceDescending,
        0,
        0,
        1.0,
        0.0,
        0,
        0.5,
        0.0,
    );
    batch.uv_rect = Float4::new(0.1, 0.2, 0.8, 0.7);
    batch.texture_sheet_columns = 4;
    batch.texture_sheet_rows = 3;
    batch.texture_sheet_frame_count = 8;
    batch.texture_sheet_frame_rate = if scenario % 2 == 0 { 0.0 } else { 3.0 };
    batch.texture_sheet_start_frame = 2;
    batch.texture_sheet_frame_randomness = 5;
    batch.start_size = 0.3;
    batch.end_size = 0.06;
    batch.start_color = Float4::new(1.0, 0.2, 0.4, 0.8);
    batch.end_color = Float4::new(0.1, 0.8, 1.0, 0.2);
    batch.uses_authored_appearance = scenario % 3 != 0;
    batch.appearance_palette = vec![
        RenderParticleAppearance::new(
            0.2,
            0.05,
            Float4::new(1.0, 0.0, 0.0, 0.8),
            Float4::new(0.0, 0.0, 1.0, 0.3),
        ),
        RenderParticleAppearance::new(
            0.3,
            0.1,
            Float4::new(0.0, 1.0, 0.0, 0.6),
            Float4::new(1.0, 1.0, 0.0, 0.1),
        ),
    ];
    batch.render_alignment = if scenario % 2 == 0 {
        ParticleRenderAlignment::Billboard
    } else {
        ParticleRenderAlignment::Velocity
    };
    batch.velocity_stretch_scale = 2.0;
    batch.velocity_stretch_max = 3.0;
    batch.render_particle_limit = if scenario % 2 == 0 { 0 } else { 67 };
    batch.render_alpha_scale = 0.75;
    batch.trail_length = if scenario % 3 == 1 { 0.0 } else { 0.8 };
    batch.trail_segments = 3;
    batch.trail_end_size_scale = 0.15;
    batch.trail_end_alpha_scale = 0.1;
    let curves: [ParticleCurve; 7] = [
        ParticleCurve::Constant(0.4),
        ParticleCurve::Linear,
        ParticleCurve::EaseIn,
        ParticleCurve::EaseOut,
        ParticleCurve::EaseInOut,
        ParticleCurve::Keyframes(vec![
            ParticleCurveKeyframe::new(1.0, 0.7),
            ParticleCurveKeyframe::new(0.3, 0.2),
            ParticleCurveKeyframe::new(0.0, 0.0),
            ParticleCurveKeyframe::new(0.3, 0.6),
        ]),
        ParticleCurve::Keyframes(Vec::new()),
    ];
    batch.size_curve = curves[(scenario % curves.len() as i64) as usize].clone();
    batch.color_curve = curves[((scenario + 2) % curves.len() as i64) as usize].clone();
    let sorting = [
        ParticleSortMode::DistanceDescending,
        ParticleSortMode::DistanceAscending,
        ParticleSortMode::OldestFirst,
        ParticleSortMode::YoungestFirst,
    ];
    let playback = [
        ParticleTextureSheetPlaybackMode::Automatic,
        ParticleTextureSheetPlaybackMode::Lifetime,
        ParticleTextureSheetPlaybackMode::PlayOnce,
        ParticleTextureSheetPlaybackMode::Loop,
        ParticleTextureSheetPlaybackMode::SingleFrame,
    ];
    batch.sort_mode = sorting[(scenario % sorting.len() as i64) as usize];
    batch.texture_sheet_playback_mode = playback[(scenario % playback.len() as i64) as usize];
    batch.world_transform.columns[0] = Float4::new(0.8, 0.4, 0.0, 0.0);
    batch.world_transform.columns[1] = Float4::new(-0.3, 1.1, 0.0, 0.0);
    batch.world_transform.columns[3] = Float4::new(0.2, 0.3, -0.4, 1.0);
    batch
}

fn bytes_of<T: Copy>(value: &T) -> Vec<u8> {
    // SAFETY: `value` is a live `Copy` value; the byte range covers exactly it.
    unsafe {
        std::slice::from_raw_parts((value as *const T).cast::<u8>(), std::mem::size_of::<T>())
    }
    .to_vec()
}

fn floats_of<T>(value: &T) -> &[f32] {
    // SAFETY: callers pass `#[repr(C)]` GPU structs whose fields are all `f32`
    // or 32-bit integers; the slice covers the whole value.
    unsafe {
        std::slice::from_raw_parts(
            (value as *const T).cast::<f32>(),
            std::mem::size_of::<T>() / 4,
        )
    }
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
            // SAFETY: the read stays inside `data` and `read_unaligned` accepts
            // the byte-aligned pointer.
            unsafe { std::ptr::read_unaligned(data.as_ptr().add(index * stride).cast::<T>()) }
        })
        .collect()
}

/// Instance layouts, truncated curve packing and the sort plan are stable.
#[test]
fn instance_layouts_and_truncated_curve_packing() {
    assert_eq!(
        std::mem::size_of::<GPUParticleSimulationInstanceUniforms>(),
        240
    );
    assert_eq!(std::mem::size_of::<GPUParticleAppearance>(), 48);
    assert_eq!(std::mem::size_of::<GPUParticleCurveKeyframe>(), 16);
    assert_eq!(std::mem::size_of::<GPUParticleSortItem>(), 16);
    assert_eq!(std::mem::size_of::<GPUParticleSortPrepareUniforms>(), 96);
    assert_eq!(std::mem::size_of::<GPUParticleSortBitonicUniforms>(), 16);

    if std::env::var_os("COVE_RESOURCE_PATH").is_some() {
        for api in [
            cove_graphics::rhi::GraphicsApi::Metal,
            cove_graphics::rhi::GraphicsApi::Vulkan,
        ] {
            let shader = diffuse_render::native::targets::native_shader_library::NativeShaderLibrary::artifact(
                "particle_sim_to_instance",
                api,
                cove_graphics::rhi::ShaderStage::Compute,
            )
            .expect("instance artifact");
            assert_eq!(shader.interface.threadgroup_specialization.x, Some(0));
            let stride = |slot: u32| {
                shader
                    .interface
                    .bindings
                    .iter()
                    .find(|binding| binding.slot == slot)
                    .map(|binding| binding.buffer.element_stride)
            };
            assert_eq!(stride(2), Some(112));
            assert_eq!(stride(4), Some(48));
        }
    }

    let mut batch = make_batch(37, 0);
    batch.size_curve = ParticleCurve::Keyframes(
        (0..150)
            .map(|index| ParticleCurveKeyframe::new(index as f32 / 149.0, index as f32))
            .collect(),
    );
    batch.color_curve = ParticleCurve::Keyframes(vec![
        ParticleCurveKeyframe::new(0.0, 0.0),
        ParticleCurveKeyframe::new(1.0, 1.0),
    ]);
    let data = GPUParticleAppearanceData::from_batch(&batch);
    assert_eq!(data.keyframes.len(), 128);
    assert_eq!(
        data.keyframes.last().expect("last keyframe").time_value,
        Float4::new(1.0, 149.0, 0.0, 0.0)
    );
    assert_eq!(data.size_curve.keyframe_range, Float2::new(0.0, 128.0));
    assert_eq!(data.color_curve.mode_constant, Float2::ZERO);
    assert_eq!(GPUParticleSortPlan::new(131).capacity, 256);
    assert_eq!(GPUParticleSortPlan::new(131).stages.len(), 36);
}

/// The sort and instance kernels are workgroup-size invariant.
#[test]
fn sort_and_instances_are_workgroup_invariant() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut programs: std::collections::BTreeMap<i64, NativeParticleInstanceKernels> =
        std::collections::BTreeMap::new();
    for scenario in 0..24_i64 {
        let group = [1_i64, 37, 64, 255, 256][(scenario % 5) as usize];
        let mut batch = make_batch(group, scenario);
        if scenario >= 20 {
            batch.appearance_palette = (0..70)
                .map(|index| {
                    RenderParticleAppearance::new(
                        index as f32 * 0.01,
                        0.04,
                        Float4::new(0.2, 0.8, 0.1, 0.7),
                        Float4::new(1.0, 0.1, 0.3, 0.0),
                    )
                })
                .collect();
            batch.particles[2].appearance_index = 69;
            batch.particles[1].appearance_index = 63;
            batch.size_curve = ParticleCurve::Keyframes(
                (0..150)
                    .map(|index| {
                        ParticleCurveKeyframe::new(index as f32 / 149.0, index as f32 / 150.0)
                    })
                    .collect(),
            );
            batch.color_curve = ParticleCurve::Keyframes(vec![
                ParticleCurveKeyframe::new(0.0, 0.0),
                ParticleCurveKeyframe::new(1.0, 1.0),
            ]);
        }
        programs.entry(group).or_insert_with(|| {
            NativeParticleInstanceKernels::new(&device, group as usize).expect("kernels")
        });
        let state =
            NativeParticleSimulationState::new(&device, batch.plan.particle_capacity as usize)
                .expect("state");
        let sort = NativeParticleSortBuffer::new(&device, batch.render_particle_count() as usize)
            .expect("sort");
        let base = 11_usize;
        let count = base + batch.render_instance_count() as usize;
        let source = NativeParticleSourceBuffer::new(&device, count + 5).expect("source");
        let states: Vec<GPUParticleSimulationState> = batch
            .particles
            .iter()
            .map(GPUParticleSimulationState::from_particle)
            .collect();
        let mut state_bytes: Vec<u8> = Vec::new();
        for state_value in &states {
            state_bytes.extend_from_slice(&bytes_of(state_value));
        }
        device
            .upload_buffer_data(state.state, 0, &state_bytes)
            .expect("upload state");
        device
            .upload_buffer_data(source.buffer, 0, &vec![0x3f_u8; source.capacity * 112])
            .expect("upload source");
        device.begin_frame().expect("frame");
        let mut commands = CommandBuffer::new();
        let report = programs
            .get(&group)
            .expect("kernels")
            .encode(
                &batch,
                &state,
                &sort,
                Float3::new(0.0, 1.0, 5.0),
                &source,
                base,
                &mut commands,
            )
            .expect("encode");
        device
            .submit(&commands, QueueClass::Graphics, &[], &[], None)
            .expect("submit");
        device.end_frame();

        let expected_state =
            NativeParticleSimulationState::new(&device, batch.plan.particle_capacity as usize)
                .expect("state");
        let expected_sort =
            NativeParticleSortBuffer::new(&device, batch.render_particle_count() as usize)
                .expect("sort");
        let expected_source =
            NativeParticleSourceBuffer::new(&device, source.capacity).expect("source");
        device
            .upload_buffer_data(expected_state.state, 0, &state_bytes)
            .expect("upload state");
        device
            .upload_buffer_data(
                expected_source.buffer,
                0,
                &vec![0x3f_u8; source.capacity * 112],
            )
            .expect("upload source");
        let comparison =
            NativeParticleInstanceKernels::new(&device, 64).expect("reference kernels");
        device.begin_frame().expect("frame");
        let mut expected_commands = CommandBuffer::new();
        let expected_report = comparison
            .encode(
                &batch,
                &expected_state,
                &expected_sort,
                Float3::new(0.0, 1.0, 5.0),
                &expected_source,
                base,
                &mut expected_commands,
            )
            .expect("encode");
        device
            .submit(&expected_commands, QueueClass::Graphics, &[], &[], None)
            .expect("submit");
        device.end_frame();

        let instances: Vec<GPUParticleInstance> =
            read_structs(&device, source.buffer, source.capacity);
        let expected: Vec<GPUParticleInstance> =
            read_structs(&device, expected_source.buffer, expected_source.capacity);
        for (index, (actual, target)) in instances.iter().zip(expected.iter()).enumerate() {
            for (a, b) in floats_of(actual).iter().zip(floats_of(target)) {
                assert!(
                    (a - b).abs() < 0.0001,
                    "scenario {scenario}, instance {index}"
                );
            }
        }
        let sorted: Vec<GPUParticleSortItem> = read_structs(&device, sort.buffer, sort.capacity);
        let expected_items: Vec<GPUParticleSortItem> =
            read_structs(&device, expected_sort.buffer, expected_sort.capacity);
        for (index, item) in expected_items.iter().enumerate() {
            let actual = &sorted[index];
            assert_eq!(actual.index, item.index, "scenario {scenario}");
            assert!(
                (actual.key - item.key).abs() < 0.0001,
                "scenario {scenario}"
            );
        }
        assert_eq!(
            report.render_instance_count,
            expected_report.render_instance_count
        );
        assert!(report.instance_dispatch_workgroups > 0);
        assert_eq!(
            report.sort_report.pass_count,
            expected_report.sort_report.pass_count
        );
        assert!(report.sort_report.dispatch_workgroups >= 0);
    }
}

/// Simulated particles, mixed draws and post effects match the reference.
#[test]
fn simulated_particles_mixed_draw_and_post_parity() {
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
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    packet.render_settings.viewport.grid_enabled = false;
    packet.render_settings.shading.debug_view_mode = DebugViewMode::Unlit;
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, 1.0, 5.0), Float3::new(0.0, 0.4, 0.0));
    packet.scene.particles = vec![RenderParticle::new(
        Float3::new(0.6, 0.4, 0.5),
        0.3,
        0.0,
        Float4::new(0.4, 0.8, 1.0, 0.6),
        None,
        Float4::new(0.0, 0.0, 1.0, 1.0),
        Float3::ZERO,
        1.0,
        None,
        None,
        diffuse_scene::rendering::render_scene::RenderParticleShape::SoftBillboard,
        0.0,
        0.0,
        ParticleBlendMode::Additive,
        None,
    )];
    let atlas = std::env::temp_dir().join(format!(
        "cove-particle-atlas-{}.bmp",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::write(&atlas, atlas_fixture()).expect("atlas fixture");
    let atlas_text = atlas.to_str().expect("UTF-8").to_string();
    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..22_i64 {
        packet.frame_index = frame;
        packet.delta_time = 0.02;
        packet.simulation_time_seconds = frame as f64 * 0.02;
        let mut a = make_batch(37, frame);
        let mut b = make_batch(255, frame + 1);
        a.emitter_entity = Some(EntityID::from_raw_value(11));
        b.emitter_entity = Some(EntityID::from_raw_value(22));
        b.blend_mode = ParticleBlendMode::Additive;
        b.world_transform.columns[3].x += 0.6;
        a.texture_path = Some(atlas_text.clone());
        b.texture_path = Some(atlas_text.clone());
        if frame == 6 {
            a.spawn_particles = vec![Particle::new(
                Float3::new(0.0, 0.4, 1.0),
                Float3::ZERO,
                0.0,
                3.0,
                1.0,
                0.0,
                0.0,
                1.0,
                Float4::new(1.0, 0.0, 1.0, 0.8),
                0,
                0,
                0,
            )];
        }
        packet.scene.particle_simulation_batches = if frame % 2 == 0 {
            vec![a, b]
        } else {
            vec![b, a]
        };
        if frame == 8 {
            packet.scene.particle_simulation_batches.clear();
        }
        if frame == 10 {
            packet.drawable_size = RenderDrawableSize::new(320, 200);
        }
        if frame == 12 {
            packet.drawable_size = RenderDrawableSize::new(192, 128);
        }
        if frame >= 14 {
            packet.render_settings.shading.pbr = true;
            packet.render_settings.shading.debug_view_mode = DebugViewMode::Shaded;
            packet.render_settings.post_processing.bloom = true;
            packet.render_settings.post_processing.taa = true;
            packet.render_settings.post_processing.fxaa = true;
        }
        renderer.render_checked(&packet).expect("native frame");
        let expected_stats = reference.render(&packet).expect("reference frame");
        let native = GridImage::readback(
            &device,
            renderer.color_texture().expect("color"),
            packet.drawable_size,
        )
        .expect("native readback");
        let expected = reference.readback().expect("reference readback");
        let difference = GridImage::difference(&native, &expected).expect("difference");
        assert!(
            difference.mean_absolute_channel_error < 0.5,
            "frame {frame}: {difference:?}"
        );
        assert!(
            difference.pixels_over_three < 1.max(difference.pixel_count / 100),
            "frame {frame}: {difference:?}"
        );
        let stats = renderer.current_frame_stats();
        assert_eq!(
            stats.gpu_particle_simulation_particle_count,
            expected_stats.gpu_particle_simulation_particle_count
        );
        assert_eq!(
            stats.gpu_particle_simulation_dispatch_workgroups,
            expected_stats.gpu_particle_simulation_dispatch_workgroups
        );
        assert_eq!(
            stats.gpu_particle_instance_dispatch_workgroups,
            expected_stats.gpu_particle_instance_dispatch_workgroups
        );
        assert_eq!(
            stats.gpu_particle_render_instance_count,
            expected_stats.gpu_particle_render_instance_count
        );
        assert_eq!(
            stats.gpu_particle_sort_pass_count,
            expected_stats.gpu_particle_sort_pass_count
        );
        assert_eq!(
            stats.gpu_particle_sort_dispatch_workgroups,
            expected_stats.gpu_particle_sort_dispatch_workgroups
        );
        assert_eq!(
            stats.gpu_particle_cull_candidate_count,
            expected_stats.gpu_particle_cull_candidate_count
        );
        assert_eq!(
            stats.gpu_particle_indirect_draw_count,
            expected_stats.gpu_particle_indirect_draw_count
        );
        assert_eq!(
            stats.pass_draw_call_counts.get(&RenderPassKind::Particles),
            expected_stats
                .pass_draw_call_counts
                .get(&RenderPassKind::Particles)
        );
        assert_eq!(
            renderer
                .drain_gpu_particle_simulation_event_snapshots(64)
                .expect("drain")
                .len(),
            reference
                .renderer
                .drain_gpu_particle_simulation_event_snapshots(64)
                .expect("drain")
                .len()
        );

        if let Some(source) = renderer.particle_simulation.source.as_ref() {
            let count = expected_stats.gpu_particle_render_instance_count as usize;
            let actual_instances: Vec<GPUParticleInstance> =
                read_structs(&device, source.buffer, count);
            let other_source = reference
                .renderer
                .particle_simulation
                .source
                .as_ref()
                .expect("reference source")
                .buffer;
            let expected_instances: Vec<GPUParticleInstance> =
                read_structs(&reference.device, other_source, count);
            let differing = actual_instances
                .iter()
                .zip(expected_instances.iter())
                .filter(|(actual, target)| {
                    !actual_instances_match(floats_of(actual), floats_of(target))
                })
                .count();
            assert_eq!(differing, 0, "frame {frame} converted instances");

            for emitter in [11_u64, 22] {
                let key = NativeParticleSimulationKey::Emitter(emitter);
                let resident = renderer
                    .particle_simulation
                    .entries
                    .get(&key)
                    .map(|entry| &entry.state)
                    .expect("resident state");
                let other = reference
                    .renderer
                    .particle_simulation
                    .entries
                    .get(&key)
                    .map(|entry| &entry.state)
                    .expect("reference resident state");
                let actual_states: Vec<GPUParticleSimulationState> =
                    read_structs(&device, resident.state, resident.capacity);
                let expected_states: Vec<GPUParticleSimulationState> =
                    read_structs(&reference.device, other.state, other.capacity);
                let differing = actual_states
                    .iter()
                    .zip(expected_states.iter())
                    .filter(|(actual, target)| {
                        actual.params != target.params
                            || !actual_instances_match(
                                &floats_of(actual)[..16],
                                &floats_of(target)[..16],
                            )
                    })
                    .count();
                assert_eq!(
                    differing, 0,
                    "frame {frame} emitter {emitter} resident states"
                );
            }
        }
        snapshots.push(native);
    }
    assert_ne!(snapshots[0], snapshots[1]);

    device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_file(&atlas);
}

fn actual_instances_match(lhs: &[f32], rhs: &[f32]) -> bool {
    lhs.iter()
        .zip(rhs.iter())
        .all(|(a, b)| a.is_finite() && b.is_finite() && (a - b).abs() <= 0.0001)
}

fn atlas_fixture() -> Vec<u8> {
    // Twelve distinct atlas cells, decoded through the production BMP path.
    fn append(data: &mut Vec<u8>, value: u32) {
        data.extend_from_slice(&value.to_le_bytes());
    }
    let mut data: Vec<u8> = vec![0x42, 0x4d];
    for value in [54 + 8 * 6 * 4, 0, 54, 40, 8, 6] {
        append(&mut data, value);
    }
    data.extend_from_slice(&[1, 0, 32, 0]);
    for value in [0, 8 * 6 * 4, 0, 0, 0, 0] {
        append(&mut data, value);
    }
    for y in 0..6 {
        for x in 0..8 {
            let cell = (y / 2) * 4 + x / 2;
            data.extend_from_slice(&[
                (20 + cell * 19) as u8,
                (240 - cell * 17) as u8,
                (30 + (cell * 53) % 210) as u8,
                (80 + cell * 15) as u8,
            ]);
        }
    }
    data
}
