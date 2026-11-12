//! Ported from `Engine/Tests/NativeRendererTests/NativeStylizedTests.swift`.

use std::sync::Arc;

use diffuse_assets::asset_pipeline::{BuiltinMesh, MeshAsset};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::mesh::mesh_outline_policy::MeshOutlinePolicy;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::targets::native_packet_validation::NativePacketValidation;
use diffuse_render::{
    RenderDrawableSize, RenderPacket, RenderPassKind, RenderSettings, StylizedCharacterStyle,
};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPalette;
use diffuse_scene::rendering::render_scene::{
    MaterialAlphaMode, RenderCamera, RenderCameraProjection, RenderDeformableMesh, RenderInstance,
    RenderLight, RenderLightType, RenderMaterial,
};

use crate::probes::animated_probe_scene::AnimatedProbeScene;
use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::probes::pbr_probe_scene::PBRProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::{device, lock_serial};

fn make_device(api: cove_graphics::rhi::GraphicsApi) -> Option<Arc<cove_graphics::rhi::Device>> {
    device::make_for(api, false).expect("device").map(Arc::new)
}

fn compare(
    device: &Arc<cove_graphics::rhi::Device>,
    renderer: &mut NativeRenderer,
    reference: &mut SceneCapture,
    packet: &RenderPacket,
    label: &str,
    directory: &std::path::Path,
) -> Vec<u8> {
    renderer.render_checked(packet).expect("native frame");
    reference.render(packet).expect("reference frame");
    let native = GridImage::readback(
        device,
        renderer.color_texture().expect("native color"),
        packet.drawable_size,
    )
    .expect("native readback");
    let expected = reference.readback().expect("reference readback");
    let delta = GridImage::difference(&native, &expected).expect("difference");
    assert!(
        delta.mean_absolute_channel_error < 0.5,
        "{label}: {delta:?}"
    );
    assert!(
        delta.pixels_over_three < 1.max(delta.pixel_count / 100),
        "{label}: {delta:?}"
    );
    GridImage::write_ppm(
        &native,
        packet.drawable_size,
        &directory.join(format!("{label}.ppm")),
    )
    .expect("native ppm");
    GridImage::write_ppm(
        &expected,
        packet.drawable_size,
        &directory.join(format!("repeat-{label}.ppm")),
    )
    .expect("reference ppm");
    native
}

/// Non-finite style values are rejected before frame preparation.
#[test]
fn nonfinite_style_rejects_before_frame_preparation() {
    let mut packet = PBRProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    packet.render_settings.stylization.enabled = true;
    packet.render_settings.stylization.style.toon_levels.z = f32::NAN;
    assert!(NativePacketValidation::validate(&packet).is_err());
    packet.render_settings.stylization.style = StylizedCharacterStyle::colorful_ink_card();
    NativePacketValidation::validate(&packet).expect("valid style");
    assert!(!MeshOutlinePolicy::includes(Some((
        Float3::ZERO,
        Float3::new(1.0, 0.0, 1.0)
    ))));
    assert!(MeshOutlinePolicy::includes(Some((
        Float3::ZERO,
        Float3::new(1.0, 1.0, 1.0)
    ))));
}

/// The default stylized look matches the reference.
#[test]
fn default_stylized_parity() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = make_device(api) else {
        return;
    };
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let directory = std::env::temp_dir().join("cove-native-stylized");
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut packet = PBRProbeScene::packet(RenderDrawableSize::new(320, 192), 0);
    packet.render_settings.stylization.enabled = true;
    compare(
        &device,
        &mut renderer,
        &mut reference,
        &packet,
        "default",
        &directory,
    );
    packet.frame_index = 1;
    packet
        .render_settings
        .stylization
        .style
        .paper_grain_strength = 0.0;
    compare(
        &device,
        &mut renderer,
        &mut reference,
        &packet,
        "no-grain",
        &directory,
    );
    device.wait_until_idle().expect("idle");
}

/// Thin backfaces and mirrored instances follow the outline policy.
#[test]
fn thin_backfaces_and_mirrors() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let mut mesh = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    mesh.indices = mesh
        .indices
        .as_chunks::<3>()
        .0
        .iter()
        .filter(|triangle| {
            triangle.iter().all(|index| {
                mesh.vertices[*index as usize * MeshAsset::VERTEX_FLOAT_COUNT
                    + MeshAsset::NORMAL_FLOAT_OFFSET
                    + 1]
                    > 0.5
            })
        })
        .flat_map(|triangle| triangle.iter().copied())
        .collect();
    for vertex in 0..mesh.vertex_count() {
        mesh.vertices[vertex * MeshAsset::VERTEX_FLOAT_COUNT + 1] = 0.0;
    }
    AssetRegistry::shared().register_for_testing(mesh, 2);
    let Some(device) = make_device(api) else {
        AssetRegistry::shared().unregister_testing_mesh(2);
        return;
    };
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let directory = std::env::temp_dir().join("cove-native-stylized");
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(128, 96), 0);
    packet.render_settings.stylization.enabled = true;
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, -3.0, 4.0), Float3::ZERO);
    packet.scene.instances = Vec::new();
    let background = compare(
        &device,
        &mut renderer,
        &mut reference,
        &packet,
        "thin-background",
        &directory,
    );
    for frame in 0..4 {
        let double_sided = frame % 2 == 1;
        let mut model = MATRIX_IDENTITY_FLOAT4X4;
        model.columns[0].x = if frame < 2 { 1.0 } else { -1.0 };
        packet.frame_index = frame + 1;
        packet.scene.instances = vec![RenderInstance::from_mesh_index(
            2,
            model,
            Float3::splat(1.0),
            RenderMaterial {
                double_sided: Some(double_sided),
                ..RenderMaterial::fallback()
            },
            None,
        )];
        let output = compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("thin-{frame}"),
            &directory,
        );
        let delta = GridImage::difference(&background, &output).expect("difference");
        if double_sided {
            assert!(delta.pixels_over_three > 50);
        } else {
            assert_eq!(delta.pixels_over_three, 0);
        }
        assert_eq!(
            renderer
                .current_frame_stats()
                .pass_draw_call_counts
                .get(&RenderPassKind::Outline)
                .copied(),
            Some(0)
        );
    }

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(2);
}

/// Materials, animation and the opaque cache match the reference over 30 frames.
#[test]
fn stylized_materials_animation_and_cache_parity() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let mut imported = MeshProbeScene::imported_fixture().expect("fixture");
    for material in &mut imported.materials {
        material.normal_texture_index = Some(0);
    }
    let mut thin = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    for vertex in 0..thin.vertex_count() {
        thin.vertices[vertex * MeshAsset::VERTEX_FLOAT_COUNT + 1] = 0.0;
    }
    let mut biased = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    for vertex in 0..biased.vertex_count() {
        biased.vertices
            [vertex * MeshAsset::VERTEX_FLOAT_COUNT + MeshAsset::MATERIAL_INDEX_FLOAT_OFFSET] = 7.0;
    }
    for (index, asset) in [
        (2, imported),
        (3, AnimatedProbeScene::skinned_fixture()),
        (4, thin),
        (5, biased),
    ] {
        AssetRegistry::shared().register_for_testing(asset, index);
    }

    let Some(device) = make_device(api) else {
        for index in 2..=5 {
            AssetRegistry::shared().unregister_testing_mesh(index);
        }
        return;
    };
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let directory = std::env::temp_dir().join("cove-native-stylized");
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut packet = PBRProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    packet.render_settings.viewport.grid_enabled = false;
    let actor = EntityID::from_raw_value(300);
    let deformable = EntityID::from_raw_value(301);
    for (index, mesh) in [2, 3, 4, 5].into_iter().enumerate() {
        let mut model = MATRIX_IDENTITY_FLOAT4X4;
        model.columns[3] = Float4::new(index as f32 * 1.8 - 2.7, 1.5, 4.0, 1.0);
        packet.scene.instances.push(RenderInstance::from_mesh_index(
            mesh,
            model,
            Float3::splat(1.0),
            RenderMaterial {
                double_sided: Some(mesh == 4),
                ..RenderMaterial::fallback()
            },
            if mesh == 3 { Some(actor) } else { None },
        ));
    }
    let mut pane = MATRIX_IDENTITY_FLOAT4X4;
    pane.columns[3] = Float4::new(0.0, 1.2, 5.0, 1.0);
    packet.scene.instances.push(RenderInstance::from_mesh_index(
        0,
        pane,
        Float3::splat(1.0),
        RenderMaterial {
            base_color_factor: Float4::new(0.3, 0.6, 0.9, 0.3),
            alpha_mode: Some(MaterialAlphaMode::Blend),
            double_sided: Some(true),
            ..RenderMaterial::fallback()
        },
        None,
    ));
    packet.joint_palette_map.palettes.insert(
        actor,
        JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, MATRIX_IDENTITY_FLOAT4X4]),
    );
    packet.scene.deformable_meshes = vec![RenderDeformableMesh::with_geometry(
        deformable,
        1,
        Some(1),
        vec![
            Float3::new(-1.0, 3.0, 2.0),
            Float3::new(1.0, 3.0, 2.0),
            Float3::new(0.0, 4.0, 2.0),
            Float3::new(0.0, 3.0, 3.0),
        ],
        vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
        Vec::new(),
        None,
    )];
    packet.scene.instances.push(RenderInstance::from_mesh_index(
        0,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        Some(deformable),
    ));

    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..30 {
        packet.frame_index = frame;
        match frame {
            1 => packet.render_settings.stylization.enabled = true,
            2 => {
                packet
                    .render_settings
                    .stylization
                    .style
                    .material_bias_strength = 0.0
            }
            3 => {
                packet
                    .render_settings
                    .stylization
                    .style
                    .material_bias_strength = 1.0
            }
            4 => packet.render_settings.stylization.style.outline_width = 0.0,
            5 => packet.render_settings.stylization.style.outline_width = 0.12,
            6 => {
                packet
                    .render_settings
                    .stylization
                    .style
                    .paper_grain_strength = 0.15
            }
            7 => {
                packet.render_settings.stylization.style.toon_levels =
                    Float4::new(0.12, 0.3, 0.8, 0.0);
                packet.render_settings.stylization.style.ink_wash_color =
                    Float4::new(0.7, 0.85, 1.0, 1.0);
            }
            8 => {
                packet.scene.lights = vec![RenderLight {
                    position: Float3::new(3.0, 4.0, 5.0),
                    direction: Float3::new(-1.0, -1.0, -1.0),
                    color: Float3::splat(1.0),
                    intensity: 2.0,
                    range: 12.0,
                    spot_inner_angle_radians: 0.3,
                    spot_outer_angle_radians: 0.9,
                    ..RenderLight::new(RenderLightType::Spot)
                }];
            }
            9 => {
                let last = packet.scene.instances.len() - 3;
                packet.scene.instances[last].transform.columns[0].x = -1.0;
            }
            10 => {
                let mut joint = MATRIX_IDENTITY_FLOAT4X4;
                joint.columns[0] = Float4::new(0.8, 0.6, 0.0, 0.0);
                joint.columns[1] = Float4::new(-0.6, 0.8, 0.0, 0.0);
                packet.joint_palette_map.palettes.insert(
                    actor,
                    JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, joint]),
                );
                packet.scene.deformable_meshes[0].revision += 1;
                packet.scene.deformable_meshes[0].positions[0].y += 0.4;
            }
            11 => {
                packet
                    .joint_palette_map
                    .palettes
                    .insert(actor, JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4]));
            }
            12 => packet.joint_palette_map.palettes.clear(),
            13 => {
                packet.joint_palette_map.palettes.insert(
                    actor,
                    JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, MATRIX_IDENTITY_FLOAT4X4]),
                );
            }
            14 => {
                packet.scene.camera.projection = RenderCameraProjection::Orthographic;
                packet.scene.camera.orthographic_height = 14.0;
            }
            15 => packet.drawable_size = RenderDrawableSize::new(192, 128),
            16 => packet.drawable_size = RenderDrawableSize::new(320, 200),
            17 => packet.render_settings.shading.pbr = false,
            18 => packet.render_settings.shading.pbr = true,
            19 => {
                packet.render_settings.shading.pbr = true;
                packet.render_settings.post_processing.ssao = true;
                packet.render_settings.post_processing.ssr = true;
                packet.render_settings.post_processing.taa = true;
                packet.render_settings.post_processing.bloom = true;
                packet.render_settings.post_processing.fxaa = true;
            }
            20 => packet.scene.camera.eye.x += 0.2,
            28 => {
                let mut invalid = packet.clone();
                invalid
                    .render_settings
                    .stylization
                    .style
                    .paper_grain_strength = f32::INFINITY;
                assert!(renderer.render_checked(&invalid).is_err());
            }
            29 => packet.render_settings.stylization.enabled = false,
            _ => {}
        }
        snapshots.push(compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("frame-{frame}"),
            &directory,
        ));
        assert_eq!(
            renderer.last_frame_used_opaque_cache(),
            reference.renderer.last_frame_used_opaque_cache(),
            "cache frame {frame}"
        );
        if frame == 1 {
            let native = renderer.current_frame_stats();
            let expected = reference.renderer.current_frame_stats();
            assert_eq!(
                native.pass_draw_call_counts.get(&RenderPassKind::Outline),
                expected.pass_draw_call_counts.get(&RenderPassKind::Outline)
            );
            assert!(
                native
                    .pass_draw_call_counts
                    .get(&RenderPassKind::Outline)
                    .copied()
                    .unwrap_or_default()
                    < native
                        .pass_draw_call_counts
                        .get(&RenderPassKind::BasePass)
                        .copied()
                        .unwrap_or_default()
            );
        }
        if frame == 17 {
            assert!(
                !renderer
                    .current_frame_stats()
                    .pass_draw_call_counts
                    .contains_key(&RenderPassKind::InkPaperPost)
            );
        }
        if frame == 27 {
            assert!(renderer.last_frame_used_opaque_cache());
            assert!(
                !renderer
                    .current_frame_stats()
                    .pass_draw_call_counts
                    .contains_key(&RenderPassKind::Outline)
            );
        }
    }
    for (a, b) in [(0_usize, 1_usize), (2, 3), (4, 5), (5, 6)] {
        assert!(
            GridImage::difference(&snapshots[a], &snapshots[b])
                .expect("difference")
                .pixels_over_three
                > 20,
            "stylized setting {a}→{b} must change pixels"
        );
    }

    device.wait_until_idle().expect("idle");
    for index in 2..=5 {
        AssetRegistry::shared().unregister_testing_mesh(index);
    }
}
