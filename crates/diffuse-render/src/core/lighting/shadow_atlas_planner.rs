//! Shared directional shadow selection, cascade fitting and atlas packing.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Lighting/ShadowAtlasPlanner.swift`.

use diffuse_math::camera::camera_matrices::CameraMatrices;
use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_cross, simd_dot, simd_length,
    simd_length_squared, simd_max, simd_min,
};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderDeformableMesh, RenderLight, RenderScene,
};

use super::shadow_atlas_plan::{ShadowAtlasLight, ShadowAtlasPlan};
use super::uniforms::{MAX_SCENE_LIGHT_UNIFORM_COUNT, MAX_SHADOW_ATLAS_TILE_COUNT, ShadowUniforms};
use crate::core::frame::render_packet::RenderDrawableSize;
use crate::core::render_settings::{DirectionalLightSelection, RenderShadowSettings};

pub enum ShadowAtlasPlanner {}

/// A mesh-bounds lookup shared with the visibility planner: `None` means the
/// mesh has no known bounds.
pub type MeshBoundsLookup<'a> = dyn Fn(i64) -> Option<(Float3, Float3)> + 'a;

impl ShadowAtlasPlanner {
    /// `makeShadowAtlasPlan(scene:drawableSize:enabled:settings:palettes:meshBounds:)`.
    #[allow(clippy::too_many_arguments)]
    pub fn make_shadow_atlas_plan(
        scene: &RenderScene,
        drawable_size: RenderDrawableSize,
        enabled: bool,
        settings: &RenderShadowSettings,
        palettes: &JointPaletteMap,
        mesh_bounds: &MeshBoundsLookup<'_>,
    ) -> ShadowAtlasPlan {
        let mut settings = *settings;
        settings.directional_cascade_count =
            RenderShadowSettings::sanitized_directional_cascade_count(
                settings.directional_cascade_count,
            );
        settings.directional_cascade_split_lambda =
            settings.directional_cascade_split_lambda.max(0.0).min(1.0);
        let tile_size = RenderShadowSettings::sanitized_map_resolution(settings.map_resolution);
        let capacity = shadow_atlas_capacity(&settings);
        let grid_dimension = shadow_atlas_grid_dimension(capacity);
        let atlas_size = tile_size * grid_dimension;
        // The disabled plan still has to carry the real camera: the mesh shader
        // derives its view vector from the shadow uniforms, so an unshadowed scene
        // must NOT zero the camera out (that breaks all view-dependent shading).
        let disabled_camera_forward = normalized_with_fallback(
            scene.camera.target - scene.camera.eye,
            Float3::new(0.0, 0.0, -1.0),
        );
        let disabled_plan = || {
            ShadowAtlasPlan::new(
                ShadowUniforms::disabled(
                    tile_size,
                    scene.camera.eye,
                    disabled_camera_forward,
                    scene.camera.projection == RenderCameraProjection::Orthographic,
                ),
                Vec::new(),
                tile_size,
                atlas_size,
                grid_dimension,
                0,
            )
        };
        if !enabled || !settings.enabled || settings.max_shadowed_directional_lights == 0 {
            return disabled_plan();
        }

        let selected_lights = selected_directional_shadow_lights(scene, &settings);
        if selected_lights.is_empty() {
            return disabled_plan();
        }
        let scene_bounds = world_bounds(scene, palettes, mesh_bounds);
        let allocations = directional_shadow_allocations(&selected_lights, &settings);
        let mut lights: Vec<ShadowAtlasLight> =
            Vec::with_capacity(allocations.iter().map(|a| a.cascade_count).sum());
        let mut params = vec![
            Float4::new(settings.depth_bias, settings.strength, 0.0, 0.0);
            MAX_SHADOW_ATLAS_TILE_COUNT
        ];
        let mut matrices = vec![MATRIX_IDENTITY_FLOAT4X4; MAX_SHADOW_ATLAS_TILE_COUNT];
        let aspect = aspect_ratio_for(drawable_size);
        let primary_cascade_count = allocations.first().map_or(0, |a| a.cascade_count);
        let cascade_splits = cascade_split_distances(
            &scene.camera,
            primary_cascade_count.max(1),
            settings.directional_cascade_split_lambda,
        );
        let mut packed_cascade_splits = Float4::splat(scene.camera.far);
        for index in 0..cascade_splits.len().min(MAX_SHADOW_ATLAS_TILE_COUNT) {
            set_lane(&mut packed_cascade_splits, index, cascade_splits[index]);
        }
        let camera_forward = normalized_with_fallback(
            scene.camera.target - scene.camera.eye,
            Float3::new(0.0, 0.0, -1.0),
        );

        let mut slot = 0usize;
        for allocation in &allocations {
            if slot >= capacity {
                break;
            }
            if allocation.cascade_count > 1 {
                for cascade_index in 0..allocation.cascade_count {
                    if slot >= capacity {
                        break;
                    }
                    let tile_x = (slot as u32) % grid_dimension;
                    let tile_y = (slot as u32) / grid_dimension;
                    let split_near = if cascade_index == 0 {
                        scene.camera.near.max(0.01)
                    } else {
                        cascade_splits[cascade_index - 1]
                    };
                    let split_far = cascade_splits[cascade_index];
                    let frustum_corners =
                        camera_frustum_corners(&scene.camera, aspect, split_near, split_far);
                    let matrix = light_view_projection_fitting(
                        &allocation.light,
                        &frustum_corners,
                        tile_size,
                    );
                    pack_shadow_tile(
                        slot,
                        tile_x,
                        tile_y,
                        tile_size,
                        atlas_size,
                        matrix,
                        &mut params,
                        &mut matrices,
                        &settings,
                    );
                    lights.push(ShadowAtlasLight {
                        scene_light_index: allocation.scene_index,
                        slot,
                        cascade_index,
                        tile_x,
                        tile_y,
                        light_view_projection: matrix,
                    });
                    slot += 1;
                }
            } else {
                let tile_x = (slot as u32) % grid_dimension;
                let tile_y = (slot as u32) / grid_dimension;
                let matrix = light_view_projection_scene_bounds(&allocation.light, scene_bounds);
                pack_shadow_tile(
                    slot,
                    tile_x,
                    tile_y,
                    tile_size,
                    atlas_size,
                    matrix,
                    &mut params,
                    &mut matrices,
                    &settings,
                );
                lights.push(ShadowAtlasLight {
                    scene_light_index: allocation.scene_index,
                    slot,
                    cascade_index: 0,
                    tile_x,
                    tile_y,
                    light_view_projection: matrix,
                });
                slot += 1;
            }
        }

        let uniforms = ShadowUniforms {
            light_view_projection0: matrices[0],
            light_view_projection1: matrices[1],
            light_view_projection2: matrices[2],
            light_view_projection3: matrices[3],
            params0: params[0],
            params1: params[1],
            params2: params[2],
            params3: params[3],
            atlas_params: Float4::new(
                1.0,
                lights.len() as f32,
                tile_size as f32,
                atlas_size as f32,
            ),
            cascade_splits: packed_cascade_splits,
            camera_position_and_padding: Float4::new(
                scene.camera.eye.x,
                scene.camera.eye.y,
                scene.camera.eye.z,
                if scene.camera.projection == RenderCameraProjection::Orthographic {
                    1.0
                } else {
                    0.0
                },
            ),
            camera_forward_and_padding: Float4::new(
                camera_forward.x,
                camera_forward.y,
                camera_forward.z,
                0.0,
            ),
        };
        ShadowAtlasPlan::new(
            uniforms,
            lights,
            tile_size,
            atlas_size,
            grid_dimension,
            primary_cascade_count,
        )
    }

    pub fn shadowed_directional_light_count(
        scene: &RenderScene,
        settings: &RenderShadowSettings,
    ) -> usize {
        if !settings.enabled || settings.max_shadowed_directional_lights == 0 {
            return 0;
        }
        selected_directional_shadow_lights(scene, settings).len()
    }
}

/// One selected light and the tile budget granted to it.
struct DirectionalShadowAllocation {
    scene_index: usize,
    light: RenderLight,
    cascade_count: usize,
}

fn aspect_ratio_for(drawable_size: RenderDrawableSize) -> f32 {
    i64::from(drawable_size.width.max(1)) as f32 / i64::from(drawable_size.height.max(1)) as f32
}

type SelectedLight = (usize, RenderLight);

fn selected_directional_shadow_lights(
    scene: &RenderScene,
    settings: &RenderShadowSettings,
) -> Vec<SelectedLight> {
    let limit = settings
        .max_shadowed_directional_lights
        .min(MAX_SHADOW_ATLAS_TILE_COUNT);
    if limit == 0 {
        return Vec::new();
    }
    let candidates: Vec<SelectedLight> = scene
        .lights
        .iter()
        .enumerate()
        .filter(|(index, light)| {
            *index < MAX_SCENE_LIGHT_UNIFORM_COUNT
                && light.type_
                    == diffuse_scene::rendering::render_scene::RenderLightType::Directional
                && light.intensity > 0.0
        })
        .map(|(index, light)| (index, light.clone()))
        .collect();
    match settings.directional_light_selection {
        DirectionalLightSelection::Brightest => {
            let mut sorted = candidates;
            sorted.sort_by(|lhs, rhs| {
                if lhs.1.intensity == rhs.1.intensity {
                    lhs.0.cmp(&rhs.0)
                } else {
                    rhs.1
                        .intensity
                        .partial_cmp(&lhs.1.intensity)
                        .unwrap_or(std::cmp::Ordering::Equal)
                }
            });
            sorted.into_iter().take(limit).collect()
        }
    }
}

fn directional_shadow_allocations(
    selected_lights: &[SelectedLight],
    settings: &RenderShadowSettings,
) -> Vec<DirectionalShadowAllocation> {
    let mut remaining_tiles = shadow_atlas_capacity(settings);
    let mut allocations: Vec<DirectionalShadowAllocation> =
        Vec::with_capacity(selected_lights.len());
    for (index, (scene_index, light)) in selected_lights.iter().enumerate() {
        if remaining_tiles == 0 {
            break;
        }
        let cascade_count = if index == 0 {
            let remaining_lights = selected_lights.len() - 1;
            let available_for_primary = (remaining_tiles - remaining_lights).max(1);
            settings
                .directional_cascade_count
                .min(available_for_primary)
        } else {
            1
        };
        allocations.push(DirectionalShadowAllocation {
            scene_index: *scene_index,
            light: light.clone(),
            cascade_count,
        });
        remaining_tiles -= cascade_count;
    }
    allocations
}

#[allow(clippy::too_many_arguments)]
fn pack_shadow_tile(
    slot: usize,
    tile_x: u32,
    tile_y: u32,
    tile_size: u32,
    atlas_size: u32,
    matrix: Float4x4,
    params: &mut [Float4],
    matrices: &mut [Float4x4],
    settings: &RenderShadowSettings,
) {
    if slot >= matrices.len() || slot >= params.len() {
        return;
    }
    matrices[slot] = matrix;
    let atlas_origin = Float3::new(
        (tile_x * tile_size) as f32 / atlas_size as f32,
        (tile_y * tile_size) as f32 / atlas_size as f32,
        0.0,
    );
    params[slot] = Float4::new(
        settings.depth_bias,
        settings.strength,
        atlas_origin.x,
        atlas_origin.y,
    );
}

fn light_view_projection_scene_bounds(
    light: &RenderLight,
    scene_bounds: (Float3, Float3),
) -> Float4x4 {
    let (scene_min, scene_max) = scene_bounds;
    let center = (scene_min + scene_max) * 0.5;
    let diagonal = scene_max - scene_min;
    let radius = (simd_length(diagonal) * 0.5).max(1.0);
    let light_direction = normalized_with_fallback(light.direction, Float3::new(0.0, -1.0, 0.0));
    let eye = center - light_direction * (radius * 2.5);
    let up = if simd_dot(light_direction, Float3::new(0.0, 1.0, 0.0)).abs() > 0.92 {
        Float3::new(0.0, 0.0, 1.0)
    } else {
        Float3::new(0.0, 1.0, 0.0)
    };
    let view = CameraMatrices::look_at_rh(eye, center, up);

    let light_space_corners: Vec<Float3> = bounds_corners(scene_min, scene_max)
        .iter()
        .map(|corner| transform_point(*corner, &view))
        .collect();
    let light_space_bounds = bounds_of(&light_space_corners);
    let margin = (radius * 0.20).max(0.5);
    let left = light_space_bounds.0.x - margin;
    let right = light_space_bounds.1.x + margin;
    let bottom = light_space_bounds.0.y - margin;
    let top = light_space_bounds.1.y + margin;
    let near = (0.05f32).max(-light_space_bounds.1.z - margin);
    let far = (near + 0.5).max(-light_space_bounds.0.z + margin);
    let projection = orthographic_rh_zo(left, right, bottom, top, near, far);
    projection * view
}

fn light_view_projection_fitting(
    light: &RenderLight,
    world_corners: &[Float3],
    tile_size: u32,
) -> Float4x4 {
    let corner_bounds = bounds_of(world_corners);
    let center = (corner_bounds.0 + corner_bounds.1) * 0.5;
    let diagonal = corner_bounds.1 - corner_bounds.0;
    let radius = (simd_length(diagonal) * 0.5).max(1.0);
    let light_direction = normalized_with_fallback(light.direction, Float3::new(0.0, -1.0, 0.0));
    let eye = center - light_direction * (radius * 2.5);
    let up = if simd_dot(light_direction, Float3::new(0.0, 1.0, 0.0)).abs() > 0.92 {
        Float3::new(0.0, 0.0, 1.0)
    } else {
        Float3::new(0.0, 1.0, 0.0)
    };
    let view = CameraMatrices::look_at_rh(eye, center, up);
    let light_space_corners: Vec<Float3> = world_corners
        .iter()
        .map(|corner| transform_point(*corner, &view))
        .collect();
    let light_space_bounds = bounds_of(&light_space_corners);
    let margin = (radius * 0.05).max(0.25);
    let width = (light_space_bounds.1.x - light_space_bounds.0.x + margin * 2.0).max(0.5);
    let height = (light_space_bounds.1.y - light_space_bounds.0.y + margin * 2.0).max(0.5);
    let center_x = (light_space_bounds.0.x + light_space_bounds.1.x) * 0.5;
    let center_y = (light_space_bounds.0.y + light_space_bounds.1.y) * 0.5;
    let texel_x = width / (tile_size.max(1) as f32);
    let texel_y = height / (tile_size.max(1) as f32);
    let snapped_center_x = (center_x / texel_x).floor() * texel_x;
    let snapped_center_y = (center_y / texel_y).floor() * texel_y;
    let left = snapped_center_x - width * 0.5;
    let right = snapped_center_x + width * 0.5;
    let bottom = snapped_center_y - height * 0.5;
    let top = snapped_center_y + height * 0.5;
    let depth_margin = (radius * 0.35).max(0.5);
    let near = (0.05f32).max(-light_space_bounds.1.z - depth_margin);
    let far = (near + 0.5).max(-light_space_bounds.0.z + depth_margin);
    let projection = orthographic_rh_zo(left, right, bottom, top, near, far);
    projection * view
}

fn world_bounds(
    scene: &RenderScene,
    palettes: &JointPaletteMap,
    mesh_bounds: &MeshBoundsLookup<'_>,
) -> (Float3, Float3) {
    if scene.instances.is_empty() {
        let center = scene.camera.target;
        let extent = Float3::splat(2.0);
        return (center - extent, center + extent);
    }

    let mut points: Vec<Float3> = Vec::with_capacity(scene.instances.len() * 8);
    // Swift's `reduce(into:)` keeps the FIRST valid mesh per entity.
    let mut deformable_meshes: std::collections::BTreeMap<EntityID, &RenderDeformableMesh> =
        std::collections::BTreeMap::new();
    for mesh in &scene.deformable_meshes {
        if mesh.is_valid() && !deformable_meshes.contains_key(&mesh.entity) {
            deformable_meshes.insert(mesh.entity, mesh);
        }
    }
    for instance in &scene.instances {
        if let Some(entity) = instance.entity
            && let Some(deformable) = deformable_meshes.get(&entity)
        {
            let (bounds_min, bounds_max) = deformable.world_bounds();
            points.extend(bounds_corners(bounds_min, bounds_max));
            continue;
        }
        let (local_min, local_max) =
            mesh_bounds(instance.mesh_index()).unwrap_or((Float3::splat(-0.5), Float3::splat(0.5)));
        // Normalized nonnegative skin weights place each vertex inside
        // the union of its joint-transformed bounds. Include identity for
        // unweighted vertices and out-of-range joint indices.
        let mut poses = vec![MATRIX_IDENTITY_FLOAT4X4];
        if let Some(entity) = instance.entity
            && let Some(palette) = palettes.palette(entity)
        {
            poses.extend(palette.matrices.iter().copied());
        }
        let corners = bounds_corners(local_min, local_max);
        for pose in &poses {
            for corner in &corners {
                points.push(transform_point(*corner, &(instance.transform * *pose)));
            }
        }
    }
    bounds_of(&points)
}

/// `cascadeSplitDistances`.
fn cascade_split_distances(camera: &RenderCamera, count: usize, lambda: f32) -> Vec<f32> {
    let cascade_count = count.clamp(1, MAX_SHADOW_ATLAS_TILE_COUNT);
    let near = camera.near.max(0.01);
    let far = camera.far.max(near + 0.1);
    if cascade_count <= 1 {
        return vec![far];
    }
    (1..=cascade_count)
        .map(|index| {
            let p = index as f32 / cascade_count as f32;
            let logarithmic = near * (far / near).powf(p);
            let uniform = near + (far - near) * p;
            lambda * logarithmic + (1.0 - lambda) * uniform
        })
        .collect()
}

fn camera_frustum_corners(
    camera: &RenderCamera,
    aspect: f32,
    near_distance: f32,
    far_distance: f32,
) -> Vec<Float3> {
    let forward = normalized_with_fallback(camera.target - camera.eye, Float3::new(0.0, 0.0, -1.0));
    let side = normalized_with_fallback(simd_cross(forward, camera.up), Float3::new(1.0, 0.0, 0.0));
    let up = normalized_with_fallback(simd_cross(side, forward), Float3::new(0.0, 1.0, 0.0));
    let tan_half_fov = (camera.fov_y_radians.max(0.001) * 0.5).tan();

    let corners_at = |distance: f32| -> [Float3; 4] {
        let height = if camera.projection == RenderCameraProjection::Orthographic {
            RenderCamera::sanitized_orthographic_height(camera.orthographic_height) * 0.5
        } else {
            distance.max(0.001) * tan_half_fov
        };
        let width = height * aspect.max(f32::EPSILON);
        let center = camera.eye + forward * distance;
        [
            center - side * width - up * height,
            center + side * width - up * height,
            center - side * width + up * height,
            center + side * width + up * height,
        ]
    };

    let near_corners = corners_at(near_distance);
    let far_corners = corners_at(far_distance);
    near_corners.into_iter().chain(far_corners).collect()
}

/// `private func normalized(_:fallback:)` — degenerate inputs fall back.
fn normalized_with_fallback(value: Float3, fallback: Float3) -> Float3 {
    let length_squared = simd_length_squared(value);
    if length_squared > f32::EPSILON {
        value / length_squared.sqrt()
    } else {
        fallback
    }
}

/// Free function shared with other modules (`shadowAtlasCapacity`).
pub fn shadow_atlas_capacity(settings: &RenderShadowSettings) -> usize {
    if settings.max_shadowed_directional_lights == 0 {
        return 1;
    }
    let requested_tiles = settings
        .max_shadowed_directional_lights
        .min(MAX_SHADOW_ATLAS_TILE_COUNT)
        + RenderShadowSettings::sanitized_directional_cascade_count(
            settings.directional_cascade_count,
        )
        .saturating_sub(1);
    1.max(requested_tiles.min(MAX_SHADOW_ATLAS_TILE_COUNT))
}

/// Free function shared with other modules (`shadowAtlasGridDimension`).
pub fn shadow_atlas_grid_dimension(capacity: usize) -> u32 {
    let clamped = capacity.clamp(1, MAX_SHADOW_ATLAS_TILE_COUNT);
    let mut dimension = 1usize;
    while dimension * dimension < clamped {
        dimension += 1;
    }
    dimension as u32
}

fn transform_point(point: Float3, matrix: &Float4x4) -> Float3 {
    let transformed = *matrix * Float4::new(point.x, point.y, point.z, 1.0);
    let w = if transformed.w.abs() > f32::EPSILON {
        transformed.w
    } else {
        1.0
    };
    Float3::new(transformed.x, transformed.y, transformed.z) / w
}

fn bounds_corners(min: Float3, max: Float3) -> [Float3; 8] {
    [
        Float3::new(min.x, min.y, min.z),
        Float3::new(max.x, min.y, min.z),
        Float3::new(min.x, max.y, min.z),
        Float3::new(max.x, max.y, min.z),
        Float3::new(min.x, min.y, max.z),
        Float3::new(max.x, min.y, max.z),
        Float3::new(min.x, max.y, max.z),
        Float3::new(max.x, max.y, max.z),
    ]
}

/// `(min, max)` over the points; no points means `(-1, 1)` on every axis.
fn bounds_of(points: &[Float3]) -> (Float3, Float3) {
    let Some(&first) = points.first() else {
        return (Float3::splat(-1.0), Float3::splat(1.0));
    };
    let mut min_point = first;
    let mut max_point = first;
    for point in &points[1..] {
        min_point = simd_min(min_point, *point);
        max_point = simd_max(max_point, *point);
    }
    (min_point, max_point)
}

/// `orthographicRH_ZO(left:right:bottom:top:near:far:)` — the free-function
/// variant used by shadow fitting (distinct from the height/aspect form in
/// `CameraMatrices`).
fn orthographic_rh_zo(
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    near: f32,
    far: f32,
) -> Float4x4 {
    let width = (right - left).max(f32::EPSILON);
    let height = (top - bottom).max(f32::EPSILON);
    let depth = (far - near).max(f32::EPSILON);
    Float4x4::from_rows(&[
        Float4::new(2.0 / width, 0.0, 0.0, -(right + left) / width),
        Float4::new(0.0, 2.0 / height, 0.0, -(top + bottom) / height),
        Float4::new(0.0, 0.0, -1.0 / depth, -near / depth),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

/// Writes one cascade split into the packed `SIMD4` without touching the rest.
fn set_lane(splits: &mut Float4, index: usize, value: f32) {
    match index {
        0 => splits.x = value,
        1 => splits.y = value,
        2 => splits.z = value,
        _ => splits.w = value,
    }
}
