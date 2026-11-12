//! The `renderExtract` phase: turn the world's render components into a `RenderScene`.
//!
//! Two behaviours here are easy to get wrong and both are deliberate:
//!
//! - **A deformable mesh's instance transform is the identity.** Backends stream
//!   soft-body vertices in world space already, so applying the authored transform would
//!   transform them twice.
//! - **Camera selection prefers the first `is_active` camera in entity order**, and only
//!   falls back to the first camera when none is active. If there is no camera at all the
//!   scene gets `RenderCamera::fallback()`, never an absent camera.

use diffuse_kernel::job_system::{JobDispatchReport, JobSystem};
use diffuse_math::simd::simd_compat::Float2;

use crate::entity_id::EntityID;
use crate::physics::character_controller::CharacterStateFrameResource;
use crate::physics::physics_frame_state::PhysicsStepClockResource;
use crate::physics::queries::spatial_queries::MeshColliderGeometryResource;
use crate::physics::soft_bodies::cloth::Cloth;
use crate::physics::soft_bodies::soft_body::{SoftBodyMesh, SoftBodyStateFrameResource};
use crate::rendering::render_extraction::{
    CameraComponent, ExtractedRenderSceneResource, LightComponent, LightType,
    RenderMaterialComponent, RenderMeshComponent,
};
use crate::rendering::render_scene::{
    ParticleRenderSummary, RenderCamera, RenderCameraProjection, RenderDeformableMesh,
    RenderInstance, RenderLight, RenderLightType, RenderMaterial, RenderMeshHandle, RenderScene,
};
use crate::runtime_world::{RuntimeWorld, WorldTransform};
use crate::scheduling::render_particles::{
    collect_particle_simulation_batches, collect_render_particles,
};

/// The result of one extraction.
pub struct RenderExtractionResult {
    pub resource: ExtractedRenderSceneResource,
    pub report: JobDispatchReport,
}

/// Extract the whole render scene for this frame.
pub fn extract_render_scene(
    world: &RuntimeWorld,
    job_system: &JobSystem,
) -> RenderExtractionResult {
    let camera_selection = select_render_camera(world, job_system);
    let deformable_meshes = collect_render_deformable_meshes(world);
    let deformable_entities: std::collections::BTreeSet<EntityID> =
        deformable_meshes.iter().map(|mesh| mesh.entity).collect();
    let instance_collection = collect_render_instances(world, job_system, &deformable_entities);
    let light_collection = collect_render_lights(world, job_system);
    let particle_collection = collect_render_particles(world, &camera_selection.camera);
    let particle_simulation_batches =
        collect_particle_simulation_batches(world, &camera_selection.camera);
    let particle_summary = ParticleRenderSummary::from_particles_with_batches(
        &particle_collection.particles,
        &particle_simulation_batches,
        Some(particle_collection.source_particle_count),
        Some(particle_collection.submitted_source_particle_count),
    );

    let instances = instance_collection.instances;
    let lights = light_collection.lights;
    let instance_entities: Vec<EntityID> =
        instances.iter().map(|extracted| extracted.entity).collect();
    let light_entities: Vec<EntityID> = lights.iter().map(|extracted| extracted.entity).collect();

    let report = JobDispatchReport::merged(
        &[
            camera_selection.report,
            instance_collection.report,
            light_collection.report,
        ],
        job_system.worker_count,
    );

    RenderExtractionResult {
        resource: ExtractedRenderSceneResource {
            scene: RenderScene {
                camera: camera_selection.camera,
                instances: instances
                    .into_iter()
                    .map(|extracted| extracted.instance)
                    .collect(),
                lights: lights
                    .into_iter()
                    .map(|extracted| extracted.light)
                    .collect(),
                environment: crate::rendering::render_scene::RenderEnvironment::fallback(),
                deformable_meshes,
                geometry_overlays: Vec::new(),
                particles: particle_collection.particles,
                particle_simulation_batches,
                particle_summary,
            },
            active_camera_entity: camera_selection.entity,
            instance_entities,
            light_entities,
            source_revision: world.revision(),
        },
        report,
    }
}

/// An instance together with the entity that produced it.
struct ExtractedInstance {
    entity: EntityID,
    instance: RenderInstance,
}

struct ExtractedLight {
    entity: EntityID,
    light: RenderLight,
}

/// Choose the camera to render from.
fn select_render_camera(world: &RuntimeWorld, job_system: &JobSystem) -> CameraSelection {
    let entities = sorted_entities(world.entities_with::<CameraComponent>());
    let (candidates, report) = job_system.parallel_compact_map(&entities, None, |entity| {
        let component = world.component::<CameraComponent>(*entity)?;
        let eye = world
            .world_transform(*entity)
            .map(|transform| transform.translation())
            .unwrap_or(diffuse_math::simd::simd_compat::Float3::ZERO);
        let camera = RenderCamera {
            eye,
            target: component.target,
            up: component.up,
            fov_y_radians: component.fov_y_radians,
            aspect_ratio: component.aspect_ratio,
            near: component.near,
            far: component.far,
            projection: RenderCameraProjection::Perspective,
            orthographic_height: 1.0,
        };
        Some((*entity, camera, component.is_active))
    });

    // The first active camera wins; otherwise the first camera is used. Both are
    // entity-ordered because `entities_with` is sorted.
    let mut fallback: Option<(Option<EntityID>, RenderCamera)> = None;
    for (entity, camera, is_active) in &candidates {
        if fallback.is_none() {
            fallback = Some((Some(*entity), *camera));
        }
        if *is_active {
            return CameraSelection {
                entity: Some(*entity),
                camera: *camera,
                report,
            };
        }
    }
    let (entity, camera) = fallback.unwrap_or((None, RenderCamera::fallback()));
    CameraSelection {
        entity,
        camera,
        report,
    }
}

struct CameraSelection {
    entity: Option<EntityID>,
    camera: RenderCamera,
    report: JobDispatchReport,
}

/// Collect drawable instances.
///
/// A non-visible mesh is skipped entirely rather than drawn with zero alpha: the
/// renderer treats presence as "draw this".
fn collect_render_instances(
    world: &RuntimeWorld,
    job_system: &JobSystem,
    deformable_entities: &std::collections::BTreeSet<EntityID>,
) -> InstanceCollection {
    let entities = sorted_entities(world.entities_with::<RenderMeshComponent>());
    let (instances, report) = job_system.parallel_compact_map(&entities, None, |entity| {
        let render_mesh = world.component::<RenderMeshComponent>(*entity)?;
        if !render_mesh.is_visible {
            return None;
        }
        let world_transform = world.world_transform(*entity)?;
        let material = world
            .component::<RenderMaterialComponent>(*entity)
            .map(|component| component.render_material())
            .unwrap_or_else(RenderMaterial::fallback);

        Some(ExtractedInstance {
            entity: *entity,
            instance: RenderInstance {
                entity: Some(*entity),
                mesh: RenderMeshHandle::new(
                    render_mesh.mesh_index,
                    render_mesh.asset_id.clone(),
                    render_mesh.levels_of_detail.clone(),
                ),
                // Deformable geometry is already in world space; using the authored
                // transform here would apply it twice.
                transform: if deformable_entities.contains(entity) {
                    diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4
                } else {
                    world_transform.matrix
                },
                color_tint: render_mesh.color_tint,
                material,
            },
        })
    });
    InstanceCollection { instances, report }
}

struct InstanceCollection {
    instances: Vec<ExtractedInstance>,
    report: JobDispatchReport,
}

/// Collect lights.
fn collect_render_lights(world: &RuntimeWorld, job_system: &JobSystem) -> LightCollection {
    let entities = sorted_entities(world.entities_with::<LightComponent>());
    let (lights, report) = job_system.parallel_compact_map(&entities, None, |entity| {
        let component = world.component::<LightComponent>(*entity)?;
        let transform = world
            .world_transform(*entity)
            .unwrap_or(WorldTransform::IDENTITY);
        Some(ExtractedLight {
            entity: *entity,
            light: RenderLight {
                position: transform.translation(),
                direction: world_forward(&transform),
                type_: match component.light_type {
                    LightType::Directional => RenderLightType::Directional,
                    LightType::Point => RenderLightType::Point,
                    LightType::Spot => RenderLightType::Spot,
                },
                color: component.color,
                intensity: component.intensity,
                range: component.range,
                spot_inner_angle_radians: component.spot_inner_angle_degrees.to_radians(),
                spot_outer_angle_radians: component.spot_outer_angle_degrees.to_radians(),
                cast_shadows: component.cast_shadows,
                ..RenderLight::default()
            },
        })
    });
    LightCollection { lights, report }
}

struct LightCollection {
    lights: Vec<ExtractedLight>,
    report: JobDispatchReport,
}

/// The world-space forward axis of a transform (its local -Z column).
fn world_forward(transform: &WorldTransform) -> diffuse_math::simd::simd_compat::Float3 {
    let column = transform.matrix.columns[2];
    diffuse_math::simd::simd_compat::Float3::new(-column.x, -column.y, -column.z)
}

/// Collect deformable meshes from the latest soft-body simulation state.
///
/// Only a body with both positions and triangle indices is drawable; a soft body that
/// has not been simulated yet has neither and is skipped. Cloth topology supplies its
/// own grid texture coordinates; an arbitrary surface falls back to the ones authored
/// with its geometry. A mesh whose buffers did not change keeps the previous frame's
/// revision and normal data, so a pinned or sleeping surface does not upload itself
/// again.
fn collect_render_deformable_meshes(world: &RuntimeWorld) -> Vec<RenderDeformableMesh> {
    let states = world
        .resource::<SoftBodyStateFrameResource>()
        .map(|resource| resource.states.clone())
        .unwrap_or_default();
    let simulated_revision = world
        .resource::<PhysicsStepClockResource>()
        .map(|clock| clock.simulated_steps.max(0) as u64)
        .unwrap_or(0);
    let geometry_resource = world.resource::<MeshColliderGeometryResource>();
    let cached: std::collections::BTreeMap<EntityID, RenderDeformableMesh> = world
        .resource::<ExtractedRenderSceneResource>()
        .map(|resource| {
            resource
                .scene
                .deformable_meshes
                .iter()
                .cloned()
                .map(|mesh| (mesh.entity, mesh))
                .collect()
        })
        .unwrap_or_default();

    let mut meshes: Vec<RenderDeformableMesh> = Vec::new();
    for (entity, state) in &states {
        if state.positions.is_empty() || state.triangle_indices.is_empty() {
            continue;
        }
        let Some(render_mesh) = world.component::<RenderMeshComponent>(*entity) else {
            continue;
        };
        if !render_mesh.is_visible {
            continue;
        }
        let texture_coordinates = cloth_texture_coordinates(
            world.component::<Cloth>(*entity).as_ref(),
            state.positions.len(),
        );
        let resolved_texture_coordinates = if texture_coordinates.is_empty() {
            world
                .component::<SoftBodyMesh>(*entity)
                .and_then(|mesh| mesh.resource_id)
                .and_then(|resource_id| {
                    geometry_resource
                        .as_ref()
                        .and_then(|geometry| geometry.geometry_for(Some(&resource_id)))
                })
                .filter(|geometry| geometry.texture_coordinates.len() == state.positions.len())
                .map(|geometry| geometry.texture_coordinates.clone())
                .unwrap_or_default()
        } else {
            texture_coordinates
        };
        if let Some(previous) = cached.get(entity)
            && previous.positions == state.positions
            && previous.triangle_indices == state.triangle_indices
            && previous.texture_coordinates == resolved_texture_coordinates
        {
            meshes.push(previous.clone());
            continue;
        }
        let previous_revision = cached.get(entity).map(|mesh| mesh.revision).unwrap_or(0);
        let next_revision = previous_revision
            .checked_add(1)
            .unwrap_or(previous_revision);
        let mesh = RenderDeformableMesh::with_geometry(
            *entity,
            simulated_revision.max(next_revision),
            None,
            state.positions.clone(),
            state.triangle_indices.clone(),
            resolved_texture_coordinates,
            None,
        );
        if mesh.is_valid() {
            meshes.push(mesh);
        }
    }
    // The scene keeps deformable meshes in entity order so the upload is stable.
    meshes.sort_by_key(|mesh| mesh.entity.raw_value());
    meshes
}

/// A cloth's vertices are a regular grid, so its texture coordinates are derived
/// from the grid resolution rather than authored.
fn cloth_texture_coordinates(cloth: Option<&Cloth>, vertex_count: usize) -> Vec<Float2> {
    let Some(cloth) = cloth else {
        return Vec::new();
    };
    if cloth.vertex_count() as usize != vertex_count {
        return Vec::new();
    }
    let denominator_x = (cloth.grid_size_x - 1).max(1) as f32;
    let denominator_z = (cloth.grid_size_z - 1).max(1) as f32;
    (0..vertex_count)
        .map(|index| {
            let x = (index as i64 % cloth.grid_size_x) as f32;
            let z = (index as i64 / cloth.grid_size_x) as f32;
            Float2::new(x / denominator_x, z / denominator_z)
        })
        .collect()
}

/// Expose the character state frame so the extraction can be extended without
/// re-reading the world.
pub fn character_states(world: &RuntimeWorld) -> CharacterStateFrameResource {
    world
        .resource::<CharacterStateFrameResource>()
        .unwrap_or_default()
}

fn sorted_entities(mut entities: Vec<EntityID>) -> Vec<EntityID> {
    entities.sort_by_key(|entity| entity.raw_value());
    entities
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use diffuse_math::simd::simd_compat::Float3;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    fn jobs() -> JobSystem {
        JobSystem::new(1, 1)
    }

    fn camera_component() -> CameraComponent {
        CameraComponent::new(
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            core::f32::consts::FRAC_PI_3,
            1.0,
            0.1,
            1000.0,
            false,
        )
    }

    #[test]
    fn an_empty_world_falls_back_to_the_default_camera() {
        let world = empty_world();
        let result = extract_render_scene(&world, &jobs());
        assert_eq!(result.resource.active_camera_entity, None);
        assert_eq!(result.resource.scene.camera, RenderCamera::fallback());
        assert!(result.resource.scene.instances.is_empty());
    }

    #[test]
    fn the_first_active_camera_wins() {
        let mut world = empty_world();
        let first = world.create_entity();
        let second = world.create_entity();
        world.set_component(
            CameraComponent {
                is_active: false,
                ..camera_component()
            },
            first,
        );
        world.set_component(
            CameraComponent {
                is_active: true,
                ..camera_component()
            },
            second,
        );
        world.propagate_transforms_default();

        let result = extract_render_scene(&world, &jobs());
        assert_eq!(result.resource.active_camera_entity, Some(second));
    }

    #[test]
    fn without_an_active_camera_the_first_camera_is_used() {
        let mut world = empty_world();
        let only = world.create_entity();
        world.set_component(
            CameraComponent {
                is_active: false,
                ..camera_component()
            },
            only,
        );
        world.propagate_transforms_default();

        let result = extract_render_scene(&world, &jobs());
        assert_eq!(result.resource.active_camera_entity, Some(only));
    }

    #[test]
    fn an_invisible_mesh_is_not_drawn() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(
            RenderMeshComponent::new(0, false, Float3::splat(1.0), None, Vec::new()),
            entity,
        );
        world.propagate_transforms_default();

        let result = extract_render_scene(&world, &jobs());
        assert!(result.resource.scene.instances.is_empty());
    }

    #[test]
    fn a_visible_mesh_becomes_one_instance() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(
            RenderMeshComponent::new(7, true, Float3::splat(1.0), None, Vec::new()),
            entity,
        );
        world.propagate_transforms_default();

        let result = extract_render_scene(&world, &jobs());
        assert_eq!(result.resource.scene.instances.len(), 1);
        assert_eq!(result.resource.scene.instances[0].mesh.mesh_index, 7);
        assert_eq!(result.resource.instance_entities, vec![entity]);
    }

    #[test]
    fn a_light_becomes_one_render_light() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(LightComponent::default(), entity);
        world.propagate_transforms_default();

        let result = extract_render_scene(&world, &jobs());
        assert_eq!(result.resource.scene.lights.len(), 1);
        assert_eq!(result.resource.light_entities, vec![entity]);
    }

    #[test]
    fn the_extraction_records_the_world_revision() {
        let world = empty_world();
        let result = extract_render_scene(&world, &jobs());
        assert_eq!(result.resource.source_revision, world.revision());
    }
}
