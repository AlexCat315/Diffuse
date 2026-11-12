//! Ported from `Engine/Tests/NativeRendererTests/NativeAnimatedMeshTests.swift`.

use std::sync::Arc;

use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::targets::native_packet_validation::NativePacketValidation;
use diffuse_render::{
    DebugViewMode, RenderDrawableSize, RenderPacket, RenderPassKind, RenderSettings,
    RenderShadowSettings,
};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{JointPalette, JointPaletteMap};
use diffuse_scene::rendering::render_scene::{
    MaterialAlphaMode, RenderCamera, RenderCameraProjection, RenderDeformableMesh, RenderInstance,
    RenderLight, RenderLightType, RenderMaterial,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::{device, lock_serial};

fn translation(x: f32, y: f32, z: f32) -> diffuse_math::simd::simd_compat::Float4x4 {
    let mut result = MATRIX_IDENTITY_FLOAT4X4;
    result.columns[3] = Float4::new(x, y, z, 1.0);
    result
}

fn packet() -> RenderPacket {
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(192, 192), 0);
    packet.scene.camera = RenderCamera {
        eye: Float3::new(0.0, 0.0, 8.0),
        target: Float3::ZERO,
        projection: RenderCameraProjection::Orthographic,
        orthographic_height: 8.0,
        ..RenderCamera::default()
    };
    packet.render_settings.shadows = RenderShadowSettings {
        enabled: true,
        map_resolution: 128,
        ..RenderShadowSettings::new_disabled()
    };
    packet.scene.lights = vec![RenderLight {
        direction: Float3::new(-0.4, -0.6, -1.0),
        intensity: 3.0,
        cast_shadows: true,
        ..RenderLight::new(RenderLightType::Directional)
    }];
    packet.scene.environment.ambient_intensity = 0.2;
    packet
}

fn quad(joint: f32) -> MeshAsset {
    let mut vertices: Vec<f32> = Vec::new();
    for p in [
        Float3::new(-1.0, -1.0, 0.0),
        Float3::new(1.0, -1.0, 0.0),
        Float3::new(1.0, 1.0, 0.0),
        Float3::new(-1.0, 1.0, 0.0),
    ] {
        MeshAsset::append_vertex(
            &mut vertices,
            p,
            Float3::new(0.0, 0.0, 1.0),
            Float3::splat(1.0),
            Float2::ZERO,
            Float4::new(1.0, 0.0, 0.0, 1.0),
            0.0,
            Float4::new(0.0, joint, 0.0, 0.0),
            if joint == 0.0 {
                Float4::new(1.0, 0.0, 0.0, 0.0)
            } else {
                Float4::new(0.25, 0.75, 0.0, 0.0)
            },
        );
    }
    MeshAsset::new("native-animated-quad", vertices, vec![0, 1, 2, 0, 2, 3])
}

fn pane(
    z: f32,
    color: Float4,
    blend: bool,
    x: f32,
    entity: Option<EntityID>,
    scale: f32,
) -> RenderInstance {
    let mut transform = translation(x, 0.0, z);
    transform.columns[0].x = scale;
    transform.columns[1].y = 2.0;
    RenderInstance::from_mesh_index(
        2,
        transform,
        Float3::splat(1.0),
        RenderMaterial {
            base_color_factor: color,
            alpha_mode: Some(if blend {
                MaterialAlphaMode::Blend
            } else {
                MaterialAlphaMode::Opaque
            }),
            double_sided: Some(true),
            ..RenderMaterial::fallback()
        },
        entity,
    )
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
        renderer.color_texture().expect("color"),
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

/// A non-finite palette is rejected before the frame is prepared.
#[test]
fn nonfinite_palette_rejected() {
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.columns[0].x = f32::NAN;
    packet.joint_palette_map = JointPaletteMap::new(
        [(EntityID::from_raw_value(1), JointPalette::new(vec![matrix]))]
            .into_iter()
            .collect(),
    );
    assert!(NativePacketValidation::validate(&packet).is_err());
}

/// Transparent panes sort by camera-axis depth and compose deterministically.
#[test]
fn transparent_ordering_depth_and_hdr() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    AssetRegistry::shared().register_for_testing(quad(0.0), 2);
    let Some(device) = device::make_for(api, false).expect("device") else {
        AssetRegistry::shared().unregister_testing_mesh(2);
        return;
    };
    let device = Arc::new(device);
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
    let directory = std::env::temp_dir().join("cove-native-animation");
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut packet = packet();
    // The near pane is laterally offset: Euclidean-distance sorting would
    // invert these panes, while camera-axis depth keeps them correct.
    packet.scene.instances = vec![
        pane(2.0, Float4::new(0.2, 0.7, 0.2, 0.5), true, 4.0, None, 8.0),
        pane(0.0, Float4::new(0.7, 0.2, 0.2, 1.0), false, 0.0, None, 8.0),
        pane(1.0, Float4::new(0.2, 0.2, 0.7, 0.5), true, 0.0, None, 8.0),
    ];
    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..7 {
        packet.frame_index = frame;
        if frame == 1 {
            packet.scene.instances.reverse();
        }
        if frame == 2 {
            packet.render_settings.shading.pbr = true;
            packet.render_settings.shading.depth_prepass = true;
        }
        if frame == 3 {
            packet.render_settings.viewport.grid_enabled = true;
            packet.scene.instances[0].transform.columns[0].x *= -1.0;
        }
        if frame == 4 {
            // A back-facing pane must render when double sided.
            packet.scene.instances[2].transform.columns[2].z = -1.0;
            packet.scene.instances[2].material.double_sided = Some(true);
        }
        if frame == 5 {
            packet.scene.instances[1].transform.columns[3].z = 3.0;
        }
        snapshots.push(compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("transparent-{frame}"),
            &directory,
        ));
        let cached = renderer.last_frame_used_opaque_cache();
        let stats = renderer.current_frame_stats();
        assert_eq!(
            stats
                .pass_draw_call_counts
                .get(&RenderPassKind::DepthPrepass)
                .copied(),
            if cached { None } else { Some(1) }
        );
        assert_eq!(
            stats
                .pass_draw_call_counts
                .get(&RenderPassKind::BasePass)
                .copied(),
            if cached { None } else { Some(1) }
        );
        assert_eq!(
            stats
                .pass_draw_call_counts
                .get(&RenderPassKind::TransparentMeshes)
                .copied(),
            Some(2)
        );
        assert_eq!(stats.instanced_mesh_batch_count, 0);
        if frame >= 2 {
            assert_eq!(
                stats
                    .pass_draw_call_counts
                    .get(&RenderPassKind::ShadowPass)
                    .copied(),
                if cached { None } else { Some(1) }
            );
        }
        assert_eq!(cached, reference.renderer.last_frame_used_opaque_cache());
    }
    assert_eq!(
        snapshots[0], snapshots[1],
        "input order cannot change transparent composition"
    );
    assert_eq!(
        snapshots[5], snapshots[6],
        "a new frame must clear the previous transparent composition"
    );
    assert!(
        GridImage::difference(&snapshots[4], &snapshots[5])
            .expect("difference")
            .pixels_over_three
            > 100
    );

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(2);
}

/// Skinned palettes reset to identity and shadows follow the posed casters.
#[test]
fn skinning_palette_reset_and_shadows() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    AssetRegistry::shared().register_for_testing(quad(1.0), 2);
    let Some(device) = device::make_for(api, false).expect("device") else {
        AssetRegistry::shared().unregister_testing_mesh(2);
        return;
    };
    let device = Arc::new(device);
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
    let directory = std::env::temp_dir().join("cove-native-animation");
    std::fs::create_dir_all(&directory).expect("output directory");
    let a = EntityID::from_raw_value(41);
    let b = EntityID::from_raw_value(42);
    let mut packet = packet();
    packet.render_settings.shading.pbr = true;
    packet.render_settings.shading.depth_prepass = true;
    packet.render_settings.shading.debug_view_mode = DebugViewMode::Shaded;
    packet.scene.instances = vec![
        pane(
            0.0,
            Float4::new(0.7, 0.3, 0.1, 1.0),
            false,
            0.0,
            Some(a),
            1.0,
        ),
        pane(
            0.0,
            Float4::new(0.2, 0.6, 0.8, 1.0),
            false,
            0.0,
            Some(b),
            1.0,
        ),
        pane(
            -1.0,
            Float4::new(0.45, 0.45, 0.45, 1.0),
            false,
            0.0,
            None,
            4.0,
        ),
    ];
    packet.joint_palette_map = JointPaletteMap::new(
        [
            (
                a,
                JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, translation(-1.4, 0.0, 0.0)]),
            ),
            (
                b,
                JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, translation(1.4, 0.0, 0.0)]),
            ),
        ]
        .into_iter()
        .collect(),
    );
    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..11 {
        packet.frame_index = frame;
        match frame {
            1 => {
                let mut pose = translation(-0.5, 0.7, 0.0);
                pose.columns[0] = Float4::new(0.35_f32.cos(), 0.0, -0.35_f32.sin(), 0.0);
                pose.columns[2] = Float4::new(0.35_f32.sin(), 0.0, 0.35_f32.cos(), 0.0);
                packet
                    .joint_palette_map
                    .palettes
                    .insert(a, JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, pose]));
            }
            2 => {
                // Joint 1 is now out of bounds.
                packet
                    .joint_palette_map
                    .palettes
                    .insert(a, JointPalette::identity());
            }
            3 => {
                packet
                    .joint_palette_map
                    .palettes
                    .insert(a, JointPalette::new(Vec::new()));
            }
            4 => {
                packet.joint_palette_map.palettes.remove(&a);
            }
            5 => {
                packet.joint_palette_map.palettes.insert(
                    a,
                    JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, translation(-1.4, 0.0, 0.0)]),
                );
            }
            6 => {
                packet.scene.instances[0].transform.columns[3].x = 20.0;
                packet.joint_palette_map.palettes.insert(
                    a,
                    JointPalette::new(vec![
                        translation(-20.0, 0.0, 0.0),
                        translation(-20.0, 0.0, 0.0),
                    ]),
                );
                packet.render_settings.visibility.frustum_culling = true;
                packet.render_settings.visibility.distance_lod = true;
            }
            7 => {
                packet.scene.instances[0].material.alpha_mode = Some(MaterialAlphaMode::Blend);
                packet.scene.instances[0].material.base_color_factor.w = 0.5;
            }
            8 => packet.render_settings.shading.debug_view_mode = DebugViewMode::WorldNormal,
            9 => {
                packet.render_settings.shading.debug_view_mode = DebugViewMode::Shaded;
                packet.scene.instances[0].transform.columns[3].x = 0.0;
                packet.scene.instances[0].material.alpha_mode = Some(MaterialAlphaMode::Opaque);
                packet.scene.instances[0].material.base_color_factor.w = 1.0;
                packet.joint_palette_map.palettes.insert(
                    a,
                    JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, translation(-1.4, 0.0, 0.0)]),
                );
            }
            10 => packet.render_settings.shadows.enabled = false,
            _ => {}
        }
        snapshots.push(compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("skin-{frame}"),
            &directory,
        ));
        // Frame 4 removes a's palette, so a is no longer posed and merges
        // with the unposed pane: colors are per-instance uniforms now.
        let stats = renderer.current_frame_stats();
        assert_eq!(
            stats.mesh_batch_count,
            if frame == 4 { 2 } else { 3 },
            "frame {frame}"
        );
        assert_eq!(stats.culled_mesh_instance_count, 0);
        assert_eq!(stats.lod_mesh_instance_count, 0);
    }
    assert!(
        GridImage::difference(&snapshots[0], &snapshots[1])
            .expect("difference")
            .pixels_over_three
            > 100
    );
    assert_eq!(
        snapshots[2], snapshots[3],
        "empty palette must reset to identity"
    );
    assert_eq!(
        snapshots[3], snapshots[4],
        "removed palette must reset to identity"
    );
    assert_eq!(
        snapshots[0], snapshots[5],
        "re-added palette must use new frame bindings"
    );
    assert!(
        GridImage::difference(&snapshots[9], &snapshots[10])
            .expect("difference")
            .pixels_over_three
            > 20,
        "posed casters must change receiver pixels"
    );

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(2);
}

/// Deformable revisions, topology changes and rollback follow the reference.
#[test]
fn deformable_revision_topology_and_rollback() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    AssetRegistry::shared().register_for_testing(quad(0.0), 2);
    let Some(device) = device::make_for(api, false).expect("device") else {
        AssetRegistry::shared().unregister_testing_mesh(2);
        return;
    };
    let device = Arc::new(device);
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
    let directory = std::env::temp_dir().join("cove-native-animation");
    std::fs::create_dir_all(&directory).expect("output directory");
    let entity = EntityID::from_raw_value(71);
    let mut packet = packet();
    packet.scene.instances = vec![pane(
        0.0,
        Float4::new(0.7, 0.6, 0.2, 1.0),
        false,
        0.0,
        Some(entity),
        1.0,
    )];
    packet.scene.instances[0].transform = MATRIX_IDENTITY_FLOAT4X4;
    let mut mesh = RenderDeformableMesh::with_geometry(
        entity,
        1,
        None,
        vec![
            Float3::new(-1.0, -1.0, 0.0),
            Float3::new(1.0, -1.0, 0.0),
            Float3::new(1.0, 1.0, 0.0),
            Float3::new(-1.0, 1.0, 0.0),
        ],
        vec![0, 1, 2, 0, 2, 3],
        Vec::new(),
        None,
    );
    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..9 {
        packet.frame_index = frame;
        match frame {
            2 => {
                mesh.revision = 2;
                mesh.positions[0].y = 0.5;
            }
            3 => {
                mesh.triangle_indices = vec![0, 2, 3];
                mesh.topology_revision = mesh.topology_revision.wrapping_add(1);
            }
            4 => {
                mesh.revision = 3;
                mesh.topology_revision = mesh.topology_revision.wrapping_add(1);
                mesh.positions.push(Float3::new(0.0, 1.5, 0.0));
                mesh.normals.push(Float3::new(0.0, 0.0, 1.0));
                mesh.texture_coordinates.push(Float2::ZERO);
                mesh.triangle_indices = vec![0, 1, 2, 0, 2, 3, 3, 2, 4];
            }
            5 => {
                mesh.revision = 4;
                mesh.positions[1].x = 0.3;
                packet.scene.deformable_meshes = vec![mesh.clone()];
                packet.scene.instances.push(RenderInstance::from_mesh_index(
                    999,
                    MATRIX_IDENTITY_FLOAT4X4,
                    Float3::splat(1.0),
                    RenderMaterial::fallback(),
                    None,
                ));
                assert!(renderer.render_checked(&packet).is_err());
                packet.scene.instances.pop();
            }
            7 => {
                packet.render_settings.shading.pbr = true;
                packet.render_settings.shading.depth_prepass = true;
            }
            _ => {}
        }
        packet.scene.deformable_meshes = if frame == 6 {
            Vec::new()
        } else {
            vec![mesh.clone()]
        };
        if frame == 8 {
            let mut invalid = mesh.clone();
            invalid.triangle_indices = vec![99, 1, 2];
            packet.scene.deformable_meshes = vec![invalid, mesh.clone(), mesh.clone()];
        }
        snapshots.push(compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("deform-{frame}"),
            &directory,
        ));
        let expected: [u64; 9] = [408, 0, 384, 12, 516, 480, 0, 516, 0];
        let stats = renderer.current_frame_stats();
        assert_eq!(
            stats.deformable_uploaded_bytes, expected[frame as usize],
            "frame {frame}"
        );
        assert_eq!(stats.deformable_mesh_count, if frame == 6 { 0 } else { 1 });
        assert_eq!(
            stats.deformable_rejected_mesh_count,
            if frame == 8 { 2 } else { 0 }
        );
    }
    assert_eq!(snapshots[0], snapshots[1]);
    assert!(
        GridImage::difference(&snapshots[1], &snapshots[2])
            .expect("difference")
            .pixels_over_three
            > 100
    );

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(2);
}
