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

use crate::entity_id::EntityID;
use crate::physics::character_controller::CharacterStateFrameResource;
use crate::physics::physics_frame_state::PhysicsStepClockResource;
use crate::physics::soft_bodies::soft_body::SoftBodyStateFrameResource;
use crate::rendering::render_extraction::{
    CameraComponent, ExtractedRenderSceneResource, LightComponent, LightType,
    RenderMaterialComponent, RenderMeshComponent,
};
use crate::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderDeformableMesh, RenderInstance, RenderLight,
    RenderLightType, RenderMaterial, RenderMeshHandle, RenderScene,
};
use crate::runtime_world::{RuntimeWorld, WorldTransform};

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
/// has not been simulated yet has neither and is skipped.
fn collect_render_deformable_meshes(world: &RuntimeWorld) -> Vec<RenderDeformableMesh> {
    let states = world
        .resource::<SoftBodyStateFrameResource>()
        .map(|resource| resource.states.clone())
        .unwrap_or_default();
    let simulated_revision = world
        .resource::<PhysicsStepClockResource>()
        .map(|clock| clock.simulated_steps.max(0) as u64)
        .unwrap_or(0);

    let mut meshes: Vec<RenderDeformableMesh> = Vec::new();
    for (entity, state) in &states {
        if state.positions.is_empty() || state.triangle_indices.is_empty() {
            continue;
        }
        if world
            .component::<RenderMeshComponent>(*entity)
            .is_some_and(|mesh| !mesh.is_visible)
        {
            continue;
        }
        let mut mesh = RenderDeformableMesh::new(*entity, simulated_revision);
        mesh.positions = state.positions.clone();
        mesh.triangle_indices = state.triangle_indices.clone();
        meshes.push(mesh);
    }
    // The scene keeps deformable meshes in entity order so the upload is stable.
    meshes.sort_by_key(|mesh| mesh.entity.raw_value());
    meshes
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
