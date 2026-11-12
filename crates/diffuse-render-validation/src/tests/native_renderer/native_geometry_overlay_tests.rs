//! Ported from `Engine/Tests/NativeRendererTests/NativeGeometryOverlayTests.swift`.

use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{GeometryLimits, PolygonMeshEdge};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::registries::mesh_picking_registry::MeshPickingSurface;
use diffuse_render::{RenderCameraMatrices, RenderDrawableSize, RenderPacket, RenderSettings};
use diffuse_scene::rendering::render_geometry_overlay::{
    RenderGeometryLine, RenderGeometryOverlay, RenderGeometryTriangle,
};
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderInstance, RenderMaterial,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::{device, lock_serial};

fn sub(a: Float3, b: Float3) -> Float3 {
    Float3::new(a.x - b.x, a.y - b.y, a.z - b.z)
}

fn scale(v: Float3, scalar: f32) -> Float3 {
    Float3::new(v.x * scalar, v.y * scalar, v.z * scalar)
}

fn add(a: Float3, b: Float3) -> Float3 {
    Float3::new(a.x + b.x, a.y + b.y, a.z + b.z)
}

fn length(v: Float3) -> f32 {
    (v.x * v.x + v.y * v.y + v.z * v.z).sqrt()
}

const RED: Float4 = Float4::new(1.0, 0.1, 0.0, 1.0);
const FILL: Float4 = Float4::new(1.0, 0.48, 0.08, 0.3);

struct Context {
    device: Arc<cove_graphics::rhi::Device>,
    renderer: NativeRenderer,
    slot: i64,
    root: std::path::PathBuf,
}

fn with_renderer(recess: bool) -> Option<Context> {
    let limits = GeometryLimits::default();
    let root = std::env::temp_dir().join(format!(
        "overlay-gpu-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    let mut mesh = GeometryPrimitives::box_mesh(Float3::splat(2.0)).expect("box");
    if recess {
        mesh.inset(&[1].into_iter().collect(), 0.3, limits)
            .expect("inset");
        mesh.extrude_faces(
            &[1].into_iter().collect(),
            Float3::new(0.0, 0.0, -0.6),
            limits,
        )
        .expect("extrude");
    }
    let document = GeometryDocument::with_source("surface", GeometrySource::Polygon { mesh });
    let url = root.join("surface.dmesh");
    let url_text = url.to_str().expect("UTF-8 path").to_string();
    document.save(&url_text, limits).expect("save document");
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let root_text = root.to_str().expect("UTF-8 path").to_string();
    let slot = assets
        .load_project_default(&root_text)
        .expect("load project")
        .first()
        .expect("mesh entry")
        .mesh_index;
    let Some(device) = device::make_for(device::platform_api(), true).expect("device") else {
        let _ = std::fs::remove_dir_all(&root);
        return None;
    };
    let device = Arc::new(device);
    let renderer = NativeRenderer::new(&device, None, assets, None, &RenderSettings::new(), &[])
        .expect("renderer");
    Some(Context {
        device,
        renderer,
        slot,
        root,
    })
}

fn render(context: &mut Context, packet: &RenderPacket) -> Vec<u8> {
    context
        .renderer
        .render_checked(packet)
        .expect("render frame");
    GridImage::readback(
        &context.device,
        context.renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback")
}

fn pixel(data: &[u8], world: Float3, packet: &RenderPacket, dx: i64, dy: i64) -> Vec<u8> {
    let matrices = RenderCameraMatrices::make(&packet.scene, packet.drawable_size);
    let clip = matrices.view_projection * Float4::new(world.x, world.y, world.z, 1.0);
    let width = packet.drawable_size.width as i64;
    let height = packet.drawable_size.height as i64;
    let x = (((clip.x / clip.w * 0.5 + 0.5) * width as f32) as i64 + dx).clamp(0, width - 1);
    let y = (((0.5 - clip.y / clip.w * 0.5) * height as f32) as i64 + dy).clamp(0, height - 1);
    let index = ((y * width + x) * 4) as usize;
    data[index..index + 4].to_vec()
}

fn is_orange(data: &[u8], world: Float3, packet: &RenderPacket, radius: i64) -> bool {
    for dy in -radius..=radius {
        for dx in -radius..=radius {
            let p = pixel(data, world, packet, dx, dy);
            if p[2] as i64 > p[1] as i64 + 70 && p[1] as i64 > p[0] as i64 + 10 {
                return true;
            }
        }
    }
    false
}

fn orthographic_camera(eye: Float3) -> RenderCamera {
    RenderCamera {
        eye,
        target: Float3::ZERO,
        projection: RenderCameraProjection::Orthographic,
        orthographic_height: 4.0,
        ..RenderCamera::default()
    }
}

/// Surface wires hide GPU diagonals and face fill respects other objects.
#[test]
fn surface_wires_hide_diagonals_and_fill_respects_objects() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let Some(mut context) = with_renderer(false) else {
        return;
    };
    let slot = context.slot;
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(256, 256), 0);
    packet.scene.camera = orthographic_camera(Float3::new(0.0, 0.0, 6.0));
    let mut blocker = MATRIX_IDENTITY_FLOAT4X4;
    blocker.columns[0].x = 0.35;
    blocker.columns[1].y = 1.2;
    blocker.columns[2].z = 0.1;
    blocker.columns[3] = Float4::new(0.2, 0.0, 1.3, 1.0);
    let instance = |transform| {
        RenderInstance::from_mesh_index(
            slot,
            transform,
            Float3::splat(1.0),
            RenderMaterial::fallback(),
            None,
        )
    };
    packet.scene.instances = vec![instance(MATRIX_IDENTITY_FLOAT4X4), instance(blocker)];
    let original = render(&mut context, &packet);

    let mut overlay = RenderGeometryOverlay::new(Float2::new(256.0, 256.0));
    overlay.triangles = vec![
        RenderGeometryTriangle {
            a: Float3::new(-1.0, -1.0, 1.0),
            b: Float3::new(1.0, -1.0, 1.0),
            c: Float3::new(1.0, 1.0, 1.0),
            color: Float4::ZERO,
            edge_widths: Float3::new(3.0, 0.0, 3.0),
            edge_a: RED,
            edge_b: RED,
            edge_c: RED,
        },
        RenderGeometryTriangle {
            a: Float3::new(-1.0, -1.0, 1.0),
            b: Float3::new(1.0, 1.0, 1.0),
            c: Float3::new(-1.0, 1.0, 1.0),
            color: Float4::ZERO,
            edge_widths: Float3::new(3.0, 3.0, 0.0),
            edge_a: RED,
            edge_b: RED,
            edge_c: RED,
        },
    ];
    packet.scene.geometry_overlays = vec![overlay.clone()];
    packet.frame_index += 1;
    let wire = render(&mut context, &packet);
    assert_eq!(
        pixel(&wire, Float3::new(-0.5, -0.5, 1.0), &packet, 0, 0),
        pixel(&original, Float3::new(-0.5, -0.5, 1.0), &packet, 0, 0)
    );
    assert!(is_orange(&wire, Float3::new(-1.0, 0.0, 1.0), &packet, 1));

    for triangle in &mut overlay.triangles {
        triangle.color = FILL;
    }
    packet.scene.geometry_overlays = vec![overlay.clone()];
    packet.frame_index += 1;
    let filled = render(&mut context, &packet);
    assert_ne!(
        pixel(&filled, Float3::new(-0.6, 0.0, 1.0), &packet, 0, 0),
        pixel(&original, Float3::new(-0.6, 0.0, 1.0), &packet, 0, 0)
    );
    assert_eq!(
        pixel(&filled, Float3::new(0.2, 0.0, 1.0), &packet, 0, 0),
        pixel(&original, Float3::new(0.2, 0.0, 1.0), &packet, 0, 0)
    );

    overlay.xray = true;
    packet.scene.geometry_overlays = vec![overlay];
    packet.frame_index += 1;
    let xray = render(&mut context, &packet);
    assert_ne!(
        pixel(&xray, Float3::new(0.2, 0.0, 1.0), &packet, 0, 0),
        pixel(&original, Float3::new(0.2, 0.0, 1.0), &packet, 0, 0)
    );

    context.device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&context.root);
}

/// Depth clips partially occluded edges and xray reveals them.
#[test]
fn depth_clips_partially_occluded_edges() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let Some(mut context) = with_renderer(false) else {
        return;
    };
    let slot = context.slot;
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(256, 256), 0);
    packet.scene.camera = orthographic_camera(Float3::new(0.0, 0.0, 6.0));
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        slot,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    let original = render(&mut context, &packet);

    let mut overlay = RenderGeometryOverlay::new(Float2::new(256.0, 256.0));
    overlay.lines = vec![RenderGeometryLine {
        a: Float3::new(-1.7, 0.0, 0.0),
        b: Float3::new(1.7, 0.0, 0.0),
        color: RED,
        width: 4.0,
    }];
    packet.scene.geometry_overlays = vec![overlay.clone()];
    packet.frame_index += 1;
    let clipped = render(&mut context, &packet);
    for x in [-1.4_f32, 1.4] {
        assert!(is_orange(&clipped, Float3::new(x, 0.0, 0.0), &packet, 1));
    }
    assert_eq!(
        pixel(&clipped, Float3::ZERO, &packet, 0, 0),
        pixel(&original, Float3::ZERO, &packet, 0, 0)
    );

    overlay.xray = true;
    packet.scene.geometry_overlays = vec![overlay];
    packet.frame_index += 1;
    let xray = render(&mut context, &packet);
    assert!(is_orange(&xray, Float3::ZERO, &packet, 1));

    packet.scene.geometry_overlays.clear();
    packet.frame_index += 1;
    let cleared = render(&mut context, &packet);
    assert_eq!(cleared, original);

    context.device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&context.root);
}

/// A recessed face fill and its edges follow depth at three camera angles.
#[test]
fn recessed_face_fill_follows_depth_at_all_angles() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let Some(mut context) = with_renderer(true) else {
        return;
    };
    let slot = context.slot;
    let limits = GeometryLimits::default();
    let mut mesh = GeometryPrimitives::box_mesh(Float3::splat(2.0)).expect("box");
    mesh.inset(&[1].into_iter().collect(), 0.3, limits)
        .expect("inset");
    mesh.extrude_faces(
        &[1].into_iter().collect(),
        Float3::new(0.0, 0.0, -0.6),
        limits,
    )
    .expect("extrude");
    let topology = mesh.topology_slice().expect("topology slice");
    let surface = MeshPickingSurface::new(&mesh.positions, &topology.triangle_indices);
    let face = mesh.faces[1].clone();
    let points: Vec<Float3> = face
        .vertices
        .iter()
        .map(|vertex| mesh.positions[*vertex as usize])
        .collect();

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(256, 256), 0);
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        slot,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    for eye in [
        Float3::new(0.0, 0.0, 6.0),
        Float3::new(4.0, 2.0, 6.0),
        Float3::new(-4.0, 2.0, 6.0),
        Float3::new(6.0, 1.0, 2.0),
    ] {
        packet.scene.camera = RenderCamera::new(eye, Float3::ZERO);
        packet.scene.geometry_overlays.clear();
        packet.frame_index += 1;
        let original = render(&mut context, &packet);

        let mut fill = RenderGeometryOverlay::new(Float2::new(256.0, 256.0));
        fill.triangles = vec![
            RenderGeometryTriangle::new(points[0], points[1], points[2], FILL),
            RenderGeometryTriangle::new(points[0], points[2], points[3], FILL),
        ];
        packet.scene.geometry_overlays = vec![fill];
        packet.frame_index += 1;
        let highlighted = render(&mut context, &packet);
        for x in [-0.45_f32, 0.0, 0.45] {
            for y in [-0.45_f32, 0.0, 0.45] {
                let p = Float3::new(x, y, 0.4);
                let offset = sub(p, eye);
                let distance = length(offset);
                let direction = scale(offset, 1.0 / distance);
                let nearest = surface
                    .hit_distance(eye, direction, distance + 0.01)
                    .unwrap_or(distance);
                if (nearest - distance).abs() < 0.001 {
                    assert_ne!(
                        pixel(&original, p, &packet, 0, 0),
                        pixel(&highlighted, p, &packet, 0, 0)
                    );
                } else if nearest < distance - 0.04 {
                    assert_eq!(
                        pixel(&original, p, &packet, 0, 0),
                        pixel(&highlighted, p, &packet, 0, 0)
                    );
                }
            }
        }

        for index in 0..points.len() {
            let a = points[index];
            let b = points[(index + 1) % points.len()];
            let mut wire = RenderGeometryOverlay::new(Float2::new(256.0, 256.0));
            let selected = PolygonMeshEdge::new(
                face.vertices[index],
                face.vertices[(index + 1) % points.len()],
            );
            for triangle in topology.triangle_indices.as_chunks::<3>().0 {
                let ids = [
                    triangle[0] as usize,
                    triangle[1] as usize,
                    triangle[2] as usize,
                ];
                let edges = [
                    PolygonMeshEdge::new(ids[1] as i64, ids[2] as i64),
                    PolygonMeshEdge::new(ids[2] as i64, ids[0] as i64),
                    PolygonMeshEdge::new(ids[0] as i64, ids[1] as i64),
                ];
                wire.triangles.push(RenderGeometryTriangle {
                    a: mesh.positions[ids[0]],
                    b: mesh.positions[ids[1]],
                    c: mesh.positions[ids[2]],
                    color: Float4::ZERO,
                    edge_widths: Float3::new(
                        if edges[0] == selected { 3.0 } else { 0.0 },
                        if edges[1] == selected { 3.0 } else { 0.0 },
                        if edges[2] == selected { 3.0 } else { 0.0 },
                    ),
                    edge_a: RED,
                    edge_b: RED,
                    edge_c: RED,
                });
            }
            packet.scene.geometry_overlays = vec![wire];
            packet.frame_index += 1;
            let image = render(&mut context, &packet);
            for step in 1..10 {
                let p = add(a, scale(sub(b, a), step as f32 / 10.0));
                let offset = sub(p, eye);
                let distance = length(offset);
                let direction = scale(offset, 1.0 / distance);
                let nearest = surface
                    .hit_distance(eye, direction, distance + 0.01)
                    .unwrap_or(distance);
                if (nearest - distance).abs() < 0.001 {
                    assert!(
                        is_orange(&image, p, &packet, 1),
                        "visible edge at {eye:?} {p:?}"
                    );
                } else if nearest < distance - 0.06 {
                    assert!(
                        !is_orange(&image, p, &packet, 0),
                        "hidden edge at {eye:?} {p:?}"
                    );
                }
            }
        }
    }

    context.device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&context.root);
}

/// The overlay sits outside the opaque cache and does not leak after clearing.
#[test]
fn overlay_outside_opaque_cache_does_not_leak() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let Some(mut context) = with_renderer(false) else {
        return;
    };
    let slot = context.slot;
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(128, 128), 0);
    packet.render_settings.shading.pbr = true;
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, 0.0, 6.0), Float3::ZERO);
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        slot,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    let original = render(&mut context, &packet);

    let mut overlay = RenderGeometryOverlay::new(Float2::new(128.0, 128.0));
    overlay.triangles = vec![RenderGeometryTriangle::new(
        Float3::new(-1.0, -1.0, 1.0),
        Float3::new(1.0, -1.0, 1.0),
        Float3::new(1.0, 1.0, 1.0),
        FILL,
    )];
    packet.scene.geometry_overlays = vec![overlay];
    packet.frame_index += 1;
    let with_overlay = render(&mut context, &packet);
    assert!(
        GridImage::difference(&original, &with_overlay)
            .expect("difference")
            .pixels_over_three
            > 100
    );

    packet.scene.geometry_overlays.clear();
    packet.frame_index += 1;
    let cleared = render(&mut context, &packet);
    assert!(context.renderer.last_frame_used_opaque_cache());
    assert_eq!(cleared, original);

    context.device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&context.root);
}
