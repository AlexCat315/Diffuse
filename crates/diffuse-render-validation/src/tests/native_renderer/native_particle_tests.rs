//! Ported from `Engine/Tests/NativeRendererTests/NativeParticleTests.swift`.

use std::sync::Arc;

use cove_graphics::rhi::{CommandBuffer, Device, QueueClass};
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_packet::RenderDrawableSize;
use diffuse_render::core::particles::particle_gpu_data::{
    GPUParticleCullBatch, GPUParticleCullUniforms, GPUParticleIndirectDrawArgs,
    GPUParticleInstance, ParticleUniforms,
};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::particles::native_particle_pass::NativeParticlePass;
use diffuse_render::native::targets::native_packet_validation::NativePacketValidation;
use diffuse_render::native::targets::native_shader_library::NativeShaderLibrary;
use diffuse_render::{RenderCameraMatrices, RenderSettings};
use diffuse_scene::particles::particle_types::ParticleBlendMode;
use diffuse_scene::rendering::render_scene::{
    ParticleRenderBatchPlan, RenderCamera, RenderEnvironment, RenderInstance, RenderMaterial,
    RenderParticle, RenderParticleShape, RenderScene,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::{device, lock_serial};

fn particle(
    position: Float3,
    size: f32,
    color: Float4,
    blend_mode: ParticleBlendMode,
) -> RenderParticle {
    RenderParticle::new(
        position,
        size,
        0.0,
        color,
        None,
        Float4::new(0.0, 0.0, 1.0, 1.0),
        Float3::ZERO,
        1.0,
        None,
        None,
        RenderParticleShape::SoftBillboard,
        0.0,
        0.0,
        blend_mode,
        None,
    )
}

fn make_scene() -> RenderScene {
    RenderScene::new(
        RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO),
        Vec::new(),
        Vec::new(),
        RenderEnvironment::default(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        None,
    )
}

fn read_buffer(device: &Device, buffer: cove_graphics::rhi::Buffer, bytes: usize) -> Vec<u8> {
    let mut data = vec![0_u8; bytes];
    device
        .read_buffer_data(buffer, 0, &mut data)
        .expect("read buffer");
    data
}

/// Particle input layouts and binary strides match the offline shaders.
#[test]
fn particle_input_and_binary_layouts() {
    assert_eq!(std::mem::size_of::<GPUParticleInstance>(), 112);
    assert_eq!(std::mem::size_of::<ParticleUniforms>(), 112);
    assert_eq!(std::mem::size_of::<GPUParticleCullUniforms>(), 80);
    assert_eq!(std::mem::size_of::<GPUParticleCullBatch>(), 16);
    assert_eq!(std::mem::size_of::<GPUParticleIndirectDrawArgs>(), 16);

    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    for api in [
        cove_graphics::rhi::GraphicsApi::Metal,
        cove_graphics::rhi::GraphicsApi::Vulkan,
    ] {
        let artifact = NativeShaderLibrary::artifact(
            "particle_cull_compact",
            api,
            cove_graphics::rhi::ShaderStage::Compute,
        )
        .expect("particle cull artifact");
        assert_eq!(artifact.interface.threadgroup_size.x, 64);
        let stride = |slot: u32| {
            artifact
                .interface
                .bindings
                .iter()
                .find(|binding| binding.slot == slot)
                .map(|binding| binding.buffer.element_stride)
        };
        assert_eq!(stride(1), Some(112));
        assert_eq!(stride(2), Some(16));
        assert_eq!(stride(4), Some(16));
    }

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    packet.scene.particles = vec![particle(
        Float3::ZERO,
        1.0,
        Float4::splat(1.0),
        ParticleBlendMode::Alpha,
    )];
    NativePacketValidation::validate(&packet).expect("valid particle packet");
    packet.scene.particles[0].texture_v_offset = f32::NAN;
    assert!(NativePacketValidation::validate(&packet).is_err());
}

/// Particle compaction produces stable indirect arguments and visible instances.
#[test]
fn particle_stable_compaction_and_indirect_arguments() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut pass = NativeParticlePass::new(&device).expect("particle pass");
    let mut scene = make_scene();
    let matrices = RenderCameraMatrices::new(
        MATRIX_IDENTITY_FLOAT4X4,
        MATRIX_IDENTITY_FLOAT4X4,
        MATRIX_IDENTITY_FLOAT4X4,
    );
    for count in [131_usize, 399, 7] {
        scene.particles = (0..count)
            .map(|index| {
                let position = Float3::new(if index % 3 == 0 { 5.0 } else { 0.0 }, 0.0, 0.0);
                let size = if index % 11 == 0 { 0.0 } else { 0.2 };
                let color = Float4::new(
                    index as f32 / count as f32,
                    0.5,
                    0.25,
                    if index % 7 == 0 { 0.0 } else { 1.0 },
                );
                let blend = if index < count / 2 {
                    ParticleBlendMode::Alpha
                } else {
                    ParticleBlendMode::Additive
                };
                particle(position, size, color, blend)
            })
            .collect();
        device.begin_frame().expect("frame");
        let mut commands = CommandBuffer::new();
        let frame = pass
            .prepare(&scene, &matrices, false, None, &mut commands)
            .expect("prepare")
            .expect("particle frame");
        device
            .submit(&commands, QueueClass::Graphics, &[], &[], None)
            .expect("submit");
        device.end_frame();
        let args = read_buffer(&device, frame.indirect, frame.draws.len() * 16);
        let visible = pass.buffers.visible.expect("visible buffer");
        let visible = read_buffer(&device, visible, count * 112);
        let batches = ParticleRenderBatchPlan::new(&scene.particles).batches;
        for (batch_index, batch) in batches.iter().enumerate() {
            let selected: Vec<usize> = (batch.start..batch.start + batch.count)
                .map(|index| index as usize)
                .filter(|index| index % 3 != 0 && index % 11 != 0 && index % 7 != 0)
                .collect();
            let offset = batch_index * 16;
            let values: Vec<u32> = (0..4)
                .map(|lane| {
                    u32::from_le_bytes(
                        args[offset + lane * 4..offset + lane * 4 + 4]
                            .try_into()
                            .expect("u32"),
                    )
                })
                .collect();
            assert_eq!(
                values,
                vec![6, selected.len() as u32, 0, batch.start as u32]
            );
            let expected: Vec<u8> = selected
                .iter()
                .flat_map(|index| {
                    let instance = GPUParticleInstance::from_particle(&scene.particles[*index]);
                    instance_bytes(instance)
                })
                .collect();
            let start = batch.start as usize * 112;
            assert_eq!(
                &visible[start..start + selected.len() * 112],
                expected.as_slice()
            );
        }
    }

    device.wait_until_idle().expect("idle");
    pass.destroy();
}

fn instance_bytes(instance: GPUParticleInstance) -> Vec<u8> {
    // SAFETY: `GPUParticleInstance` is `Copy` and `#[repr(C)]`; the range is
    // fully initialized.
    unsafe {
        std::slice::from_raw_parts(
            (&instance as *const GPUParticleInstance).cast::<u8>(),
            std::mem::size_of::<GPUParticleInstance>(),
        )
    }
    .to_vec()
}

fn texture_fixture() -> Vec<u8> {
    // A 2×2, bottom-up BGRA BMP exercises the real production decoder.
    fn append(data: &mut Vec<u8>, value: u32) {
        data.extend_from_slice(&value.to_le_bytes());
    }
    let mut data: Vec<u8> = vec![0x42, 0x4d];
    for value in [70, 0, 54, 40, 2, 2] {
        append(&mut data, value);
    }
    data.extend_from_slice(&[1, 0, 32, 0]);
    for value in [0, 16, 0, 0, 0, 0] {
        append(&mut data, value);
    }
    data.extend_from_slice(&[
        255, 32, 16, 255, 16, 255, 32, 255, 16, 32, 255, 255, 255, 255, 255, 128,
    ]);
    data
}

/// Billboards, ribbons, blending, textures and the opaque cache match the reference.
#[test]
fn billboards_ribbons_blending_depth_textures_and_cache_parity() {
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

    let texture_path = std::env::temp_dir().join("cove-native-particle-texture.bmp");
    let retry_path = std::env::temp_dir().join("cove-no-particle-texture");
    std::fs::write(&texture_path, texture_fixture()).expect("write texture fixture");
    let texture_text = texture_path.to_str().expect("UTF-8").to_string();
    let retry_text = retry_path.to_str().expect("UTF-8").to_string();

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    packet.render_settings.viewport.grid_enabled = false;
    packet.render_settings.shading.debug_view_mode = diffuse_render::DebugViewMode::Unlit;
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, 0.0, 7.0), Float3::ZERO);
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        0,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    packet.scene.particles = vec![
        RenderParticle::new(
            Float3::new(-1.0, 0.0, 1.2),
            1.5,
            0.4,
            Float4::new(0.9, 0.3, 0.2, 0.8),
            None,
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::ZERO,
            1.0,
            None,
            None,
            RenderParticleShape::SoftBillboard,
            0.0,
            0.0,
            ParticleBlendMode::Alpha,
            None,
        ),
        RenderParticle::new(
            Float3::new(1.0, 0.0, 1.3),
            1.6,
            0.0,
            Float4::new(0.2, 0.5, 1.0, 0.7),
            None,
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::ZERO,
            1.0,
            None,
            None,
            RenderParticleShape::SoftBillboard,
            0.0,
            0.0,
            ParticleBlendMode::Additive,
            None,
        ),
        particle(
            Float3::new(0.0, 0.0, -1.2),
            0.8,
            Float4::new(0.0, 1.0, 0.0, 1.0),
            ParticleBlendMode::Alpha,
        ),
        RenderParticle::new(
            Float3::new(0.0, 1.5, 0.0),
            1.0,
            0.0,
            Float4::new(0.9, 0.8, 0.2, 0.7),
            Some(Float4::new(0.2, 0.1, 0.9, 0.1)),
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::new(1.0, 1.0, 0.0),
            2.0,
            Some(0.6),
            Some(0.05),
            RenderParticleShape::RibbonSegment,
            0.15,
            2.3,
            ParticleBlendMode::Alpha,
            Some(texture_text.clone()),
        ),
        RenderParticle::new(
            Float3::new(-2.0, -1.2, 0.0),
            0.7,
            0.0,
            Float4::new(0.3, 0.9, 0.7, 0.6),
            None,
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::new(1.0, 0.5, 0.1),
            2.5,
            None,
            None,
            RenderParticleShape::SoftBillboard,
            0.0,
            0.0,
            ParticleBlendMode::Alpha,
            Some(texture_text.clone()),
        ),
        RenderParticle::new(
            Float3::new(2.0, -1.2, 0.0),
            0.7,
            0.0,
            Float4::new(0.8, 0.2, 0.9, 0.6),
            None,
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::ZERO,
            1.0,
            None,
            None,
            RenderParticleShape::SoftBillboard,
            0.0,
            0.0,
            ParticleBlendMode::Alpha,
            Some(retry_text.clone()),
        ),
    ];
    let originals = packet.scene.particles.clone();
    let directory = std::env::temp_dir().join("cove-native-particles");
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..26 {
        packet.frame_index = frame;
        match frame {
            1 => packet.scene.particles[1].blend_mode = ParticleBlendMode::Alpha,
            2 => packet.scene.particles[0].texture_path = Some(texture_text.clone()),
            3 => {
                packet.scene.particles[0].uv_rect = Float4::new(0.0, 0.0, 0.5, 0.5);
            }
            4 => packet.scene.particles[0].rotation += 0.7,
            5 => {
                packet.scene.particles[3].texture_v_scale = 0.0;
                packet.scene.particles[3].end_color = packet.scene.particles[3].color;
            }
            6 => packet.scene.particles.reverse(),
            7 => {
                for index in 0..400 {
                    let position = Float3::new(
                        (index % 20) as f32 * 0.25 - 2.5,
                        (index / 20) as f32 * 0.18 - 1.8,
                        2.0,
                    );
                    packet.scene.particles.push(particle(
                        position,
                        0.08,
                        Float4::new(1.0, 0.5, 0.1, 0.5),
                        if index % 3 == 0 {
                            ParticleBlendMode::Additive
                        } else {
                            ParticleBlendMode::Alpha
                        },
                    ));
                }
            }
            8 => packet.scene.particles = originals.clone(),
            9 => packet.drawable_size = RenderDrawableSize::new(192, 128),
            10 => packet.drawable_size = RenderDrawableSize::new(320, 200),
            11 => {
                packet.scene.camera.projection =
                    diffuse_scene::rendering::render_scene::RenderCameraProjection::Orthographic;
                packet.scene.camera.orthographic_height = 6.0;
            }
            12 => {
                packet.render_settings.shading.pbr = true;
                packet.render_settings.post_processing.bloom = true;
                packet.render_settings.post_processing.taa = true;
                packet.render_settings.post_processing.fxaa = true;
            }
            21 => packet.scene.particles[0].position.x += 0.5,
            22 => packet.scene.particles.clear(),
            23 => packet.scene.particles = originals.clone(),
            24 => {
                let mut invalid = packet.clone();
                invalid.scene.particles[0].end_color.z = f32::INFINITY;
                assert!(renderer.render_checked(&invalid).is_err());
                std::fs::write(&retry_path, texture_fixture()).expect("write retry texture");
            }
            25 => {
                packet.render_settings.shading.pbr = false;
                packet.render_settings.post_processing.bloom = false;
                packet.render_settings.post_processing.taa = false;
                packet.render_settings.post_processing.fxaa = false;
            }
            _ => {}
        }
        renderer.render_checked(&packet).expect("native frame");
        reference.render(&packet).expect("reference frame");
        let native = GridImage::readback(
            &device,
            renderer.color_texture().expect("color"),
            packet.drawable_size,
        )
        .expect("native readback");
        let expected = reference.readback().expect("reference readback");
        let delta = GridImage::difference(&native, &expected).expect("difference");
        assert!(
            delta.mean_absolute_channel_error < 0.5,
            "frame {frame}: {delta:?}"
        );
        assert!(
            delta.pixels_over_three < 1.max(delta.pixel_count / 100),
            "frame {frame}: {delta:?}"
        );
        let stats = renderer.current_frame_stats();
        let reference_stats = reference.renderer.current_frame_stats();
        assert_eq!(
            stats.gpu_particle_cull_candidate_count,
            packet.scene.particles.len() as i64
        );
        assert_eq!(
            stats.gpu_particle_cull_batch_count,
            reference_stats.gpu_particle_cull_batch_count
        );
        assert_eq!(
            stats.gpu_particle_indirect_draw_count,
            reference_stats.gpu_particle_indirect_draw_count
        );
        assert_eq!(
            renderer.last_frame_used_opaque_cache(),
            reference.renderer.last_frame_used_opaque_cache()
        );
        if frame == 20 || frame == 21 || frame == 22 {
            assert!(renderer.last_frame_used_opaque_cache());
        }
        GridImage::write_ppm(
            &native,
            packet.drawable_size,
            &directory.join(format!("frame-{frame}.ppm")),
        )
        .expect("native ppm");
        GridImage::write_ppm(
            &expected,
            packet.drawable_size,
            &directory.join(format!("repeat-{frame}.ppm")),
        )
        .expect("reference ppm");
        snapshots.push(native);
    }
    for (a, b) in [
        (0_usize, 1_usize),
        (1, 2),
        (2, 3),
        (3, 4),
        (4, 5),
        (20, 21),
        (21, 22),
        (22, 23),
        (23, 24),
    ] {
        assert!(
            GridImage::difference(&snapshots[a], &snapshots[b])
                .expect("difference")
                .pixels_over_three
                > 20,
            "particle change {a}→{b}"
        );
    }

    device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_file(&texture_path);
    let _ = std::fs::remove_file(&retry_path);
}
