//! `Editor/Sources/EditorCore/Scene/Adapter/ViewportInteraction.swift`.
//!
//! Picking, overlay geometry, framing and viewport camera control for the
//! editor scene adapter.
//!
//! Swift's private helpers that only touch values (matrix construction, line
//! tessellation, camera math) are module-level functions here; helpers that
//! read scene state stay methods on [`EditorSceneAdapter`].

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::f32::consts::PI;

use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_kernel::input_event::KeyModifiers;
use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, Quatf, simd_cross, simd_determinant,
    simd_distance, simd_dot, simd_inverse, simd_length, simd_length_squared, simd_length_squared4,
    simd_max, simd_min, simd_normalize,
};
use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;
use diffuse_render::registries::mesh_picking_registry::{MeshPickingRegistry, MeshPickingSurface};
use diffuse_render::registries::mesh_wireframe_registry::MeshWireframeRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::character_controller::CharacterGroundState;
use diffuse_scene::physics::collider::{ColliderShape, ColliderShapeInstance, SpatialAABB};
use diffuse_scene::physics::destruction::Destructible;
use diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointConfiguration;
use diffuse_scene::physics::physics_debug_frame::PhysicsDebugConstraint;
use diffuse_scene::physics::physics_events::PhysicsContactEventKind;
use diffuse_scene::physics::queries::physics_query_types::{
    PhysicsQueryFilter, PhysicsRaycastQuery,
};
use diffuse_scene::physics::queries::spatial_queries::MeshColliderGeometryResource;
use diffuse_scene::physics::soft_bodies::cloth::Cloth;
use diffuse_scene::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::editing::viewport::editor_viewport_projection::{
    EditorViewportFraming, EditorViewportProjection,
};
use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::state::editor_state::EditorPhysicsDebugOverlayOptions;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorSoftBodyConstraintKind {
    Surface,
    Volume,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorSoftBodyConstraintLine {
    pub vertex_a: u32,
    pub vertex_b: u32,
    pub position_a: Float3,
    pub position_b: Float3,
    pub kind: EditorSoftBodyConstraintKind,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorSoftBodyFixedVertexMarker {
    pub vertex: u32,
    pub position: Float3,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorSoftBodyConstraintOverlay {
    pub lines: Vec<EditorSoftBodyConstraintLine>,
    pub fixed_vertices: Vec<EditorSoftBodyFixedVertexMarker>,
    pub uses_simulated_positions: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorDestructionConnectionLine {
    pub connection_id: u32,
    pub fragment_a: u32,
    pub fragment_b: u32,
    pub position_a: Float3,
    pub position_b: Float3,
    pub is_broken: bool,
    pub is_source_fractured: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorPhysicsDebugLineKind {
    Collider,
    Bounds,
    Joint,
    JointAxis,
    JointLimit,
    CharacterGround,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorPhysicsDebugLine {
    pub entity_id: u64,
    pub position_a: Float3,
    pub position_b: Float3,
    pub kind: EditorPhysicsDebugLineKind,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorPhysicsContactMarker {
    pub entity_a: u64,
    pub entity_b: u64,
    pub position: Float3,
    pub normal_end: Float3,
    pub kind: PhysicsContactEventKind,
    pub penetration_depth: f32,
    pub impulse: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorPhysicsDebugOverlay {
    pub lines: Vec<EditorPhysicsDebugLine>,
    pub contacts: Vec<EditorPhysicsContactMarker>,
    pub sleeping_body_entity_ids: BTreeSet<u64>,
    pub trigger_body_entity_ids: BTreeSet<u64>,
    pub grounded_character_entity_ids: BTreeSet<u64>,
    pub selected_body_is_sleeping: bool,
    pub selected_body_is_trigger: bool,
    pub character_ground_state: Option<CharacterGroundState>,
}

impl EditorPhysicsDebugOverlay {
    /// Swift's `static let empty`.
    pub fn empty() -> Self {
        EditorPhysicsDebugOverlay {
            lines: Vec::new(),
            contacts: Vec::new(),
            sleeping_body_entity_ids: BTreeSet::new(),
            trigger_body_entity_ids: BTreeSet::new(),
            grounded_character_entity_ids: BTreeSet::new(),
            selected_body_is_sleeping: false,
            selected_body_is_trigger: false,
            character_ground_state: None,
        }
    }
}

/// Swift's private `ViewportRay`.
#[derive(Clone, Copy, Debug)]
struct ViewportRay {
    origin: Float3,
    direction: Float3,
}

impl EditorSceneAdapter {
    // MARK: - Picking

    /// Picks the nearest actual mesh surface. Collider fallback is restricted
    /// to entities without a rendered mesh, so a surface miss stays a miss.
    pub fn pick_entity(
        &self,
        cursor_x: f32,
        cursor_y: f32,
        frame: ViewportScreenFrame,
    ) -> Option<u64> {
        let ray = self.viewport_ray(cursor_x, cursor_y, frame)?;
        if let Some(hit) = self.pick_rendered_entity(ray) {
            return Some(hit);
        }
        let ignored: BTreeSet<EntityID> = self
            .scene()
            .extracted_render_scene()
            .map(|extracted| extracted.instance_entities.into_iter().collect())
            .unwrap_or_default();
        self.with_scene_mut(|scene| {
            scene.physics_raycast(
                PhysicsRaycastQuery::with_distance(ray.origin, ray.direction, 10_000.0),
                PhysicsQueryFilter {
                    ignored_entities: ignored,
                    include_triggers: true,
                    ..Default::default()
                },
            )
        })
        .map(|hit| hit.entity.raw_value())
    }

    fn pick_rendered_entity(&self, ray: ViewportRay) -> Option<u64> {
        self.rendered_surface_hit(ray, None)
            .map(|(entity, _distance)| entity.raw_value())
    }

    /// `meshSurfaceDistance(origin:direction:ignoringEntity:)`.
    pub fn mesh_surface_distance(
        &self,
        origin: Float3,
        direction: Float3,
        ignoring_entity: Option<u64>,
    ) -> Option<f32> {
        self.rendered_surface_hit(ViewportRay { origin, direction }, ignoring_entity)
            .map(|(_entity, distance)| distance)
    }

    /// Swift's `ignoringEntity: nil` default.
    pub fn mesh_surface_distance_default(&self, origin: Float3, direction: Float3) -> Option<f32> {
        self.mesh_surface_distance(origin, direction, None)
    }

    fn rendered_surface_hit(
        &self,
        ray: ViewportRay,
        ignoring: Option<u64>,
    ) -> Option<(EntityID, f32)> {
        let extracted = self.scene().extracted_render_scene()?;
        let palettes = self.current_joint_palette_map();
        let mut deformables: BTreeMap<
            EntityID,
            diffuse_scene::rendering::render_scene::RenderDeformableMesh,
        > = BTreeMap::new();
        for deformable in &extracted.scene.deformable_meshes {
            deformables
                .entry(deformable.entity)
                .or_insert_with(|| deformable.clone());
        }
        let mut nearest: f32 = 10_000.0;
        let mut selected: Option<EntityID> = None;
        for (index, entity) in extracted.instance_entities.iter().enumerate() {
            if Some(entity.raw_value()) == ignoring {
                continue;
            }
            let Some(instance) = extracted.scene.instances.get(index) else {
                continue;
            };
            let surface: Option<MeshPickingSurface>;
            let transform: Float4x4;
            if let Some(deformable) = deformables
                .get(entity)
                .filter(|deformable| deformable.is_valid())
            {
                surface = Some(MeshPickingSurface::new(
                    &deformable.positions,
                    &deformable.triangle_indices,
                ));
                transform = MATRIX_IDENTITY_FLOAT4X4;
            } else {
                let joints = palettes
                    .palette(*entity)
                    .map(|palette| palette.matrices.clone())
                    .unwrap_or_default();
                let mut selected_surface =
                    MeshPickingRegistry::surface(instance.mesh.mesh_index, &joints);
                if joints.is_empty() {
                    let column = instance.transform.columns[3];
                    let distance = simd_distance(
                        self.current_render_camera().eye,
                        Float3::new(column.x, column.y, column.z),
                    );
                    let mut levels_of_detail = instance.mesh.levels_of_detail.clone();
                    levels_of_detail.sort_by(|lhs, rhs| {
                        lhs.minimum_distance
                            .partial_cmp(&rhs.minimum_distance)
                            .unwrap_or(Ordering::Equal)
                    });
                    for lod in levels_of_detail {
                        if !lod.minimum_distance.is_finite() || distance < lod.minimum_distance {
                            continue;
                        }
                        if let Some(simplified) = MeshPickingRegistry::surface(lod.mesh_index, &[])
                        {
                            selected_surface = Some(simplified);
                        }
                    }
                }
                surface = selected_surface;
                transform = instance.transform;
            }
            let determinant = simd_determinant(transform);
            let Some(surface) = surface else {
                continue;
            };
            if !determinant.is_finite() || determinant == 0.0 {
                continue;
            }
            let inverse = simd_inverse(transform);
            let origin = inverse * Float4::new(ray.origin.x, ray.origin.y, ray.origin.z, 1.0);
            let direction =
                inverse * Float4::new(ray.direction.x, ray.direction.y, ray.direction.z, 0.0);
            if let Some(distance) = surface.hit_distance(
                Float3::new(origin.x, origin.y, origin.z),
                Float3::new(direction.x, direction.y, direction.z),
                nearest,
            ) {
                nearest = distance;
                selected = Some(*entity);
            }
        }
        selected.map(|entity| (entity, nearest))
    }

    /// 返回与屏幕矩形相交的实体集合。用于视口框选。
    pub fn pick_entities(
        &self,
        screen_rect: ViewportScreenFrame,
        frame: ViewportScreenFrame,
    ) -> BTreeSet<u64> {
        let Some(extracted) = self.scene().extracted_render_scene() else {
            return BTreeSet::new();
        };
        let rect_min_x = screen_rect.x.min(screen_rect.x + screen_rect.width);
        let rect_max_x = screen_rect.x.max(screen_rect.x + screen_rect.width);
        let rect_min_y = screen_rect.y.min(screen_rect.y + screen_rect.height);
        let rect_max_y = screen_rect.y.max(screen_rect.y + screen_rect.height);

        let mut hits: BTreeSet<u64> = BTreeSet::new();
        for (index, entity) in extracted.instance_entities.iter().enumerate() {
            let Some(instance) = extracted.scene.instances.get(index) else {
                continue;
            };
            let (local_min, local_max) = MeshBoundsRegistry::bounds(instance.mesh.mesh_index)
                .unwrap_or_else(|| (Float3::new(-0.5, -0.5, -0.5), Float3::new(0.5, 0.5, 0.5)));
            let corners = world_aabb_corners(local_min, local_max, instance.transform);
            let mut sx0: f32 = f32::MAX;
            let mut sy0: f32 = f32::MAX;
            let mut sx1: f32 = -f32::MAX;
            let mut sy1: f32 = -f32::MAX;
            let mut has_projected_corner = false;
            for corner in corners {
                let Some((x, y)) = self.project_to_viewport(corner, frame) else {
                    continue;
                };
                has_projected_corner = true;
                sx0 = sx0.min(x);
                sy0 = sy0.min(y);
                sx1 = sx1.max(x);
                sy1 = sy1.max(y);
            }
            if !has_projected_corner {
                continue;
            }
            let overlap_x = sx1 >= rect_min_x && sx0 <= rect_max_x;
            let overlap_y = sy1 >= rect_min_y && sy0 <= rect_max_y;
            if overlap_x && overlap_y {
                hits.insert(entity.raw_value());
            }
        }
        hits
    }

    /// 返回渲染实例世界 AABB，供 wireframe overlay 绘制。
    pub fn viewport_world_bounds(&self) -> Vec<(u64, Float3, Float3)> {
        let Some(extracted) = self.scene().extracted_render_scene() else {
            return Vec::new();
        };
        extracted
            .instance_entities
            .iter()
            .enumerate()
            .map(|(index, entity)| {
                let instance = &extracted.scene.instances[index];
                let (local_min, local_max) = MeshBoundsRegistry::bounds(instance.mesh.mesh_index)
                    .unwrap_or_else(|| (Float3::new(-0.5, -0.5, -0.5), Float3::new(0.5, 0.5, 0.5)));
                let (min, max) = world_aabb(local_min, local_max, instance.transform);
                (entity.raw_value(), min, max)
            })
            .collect()
    }

    /// 返回真实 mesh 边线（已变换到世界空间），用于 viewport wireframe overlay。
    ///
    /// The tuple is `(entity_id, a, b)`.
    pub fn viewport_wireframe_lines(
        &self,
        max_edges_per_mesh: usize,
    ) -> Vec<(u64, Float3, Float3)> {
        let Some(extracted) = self.scene().extracted_render_scene() else {
            return Vec::new();
        };
        let mut lines: Vec<(u64, Float3, Float3)> =
            Vec::with_capacity(extracted.scene.instances.len() * 256);

        for (index, entity) in extracted.instance_entities.iter().enumerate() {
            let instance = &extracted.scene.instances[index];
            let Some(edges) = MeshWireframeRegistry::edges(instance.mesh.mesh_index) else {
                continue;
            };
            if edges.is_empty() {
                continue;
            }
            let stride = (edges.len() / max_edges_per_mesh.max(1)).max(1);
            let mut edge_index = 0;
            while edge_index < edges.len() {
                let edge = edges[edge_index];
                let wa = instance.transform * Float4::new(edge.a.x, edge.a.y, edge.a.z, 1.0);
                let wb = instance.transform * Float4::new(edge.b.x, edge.b.y, edge.b.z, 1.0);
                lines.push((
                    entity.raw_value(),
                    Float3::new(wa.x, wa.y, wa.z),
                    Float3::new(wb.x, wb.y, wb.z),
                ));
                edge_index += stride;
            }
        }
        lines
    }

    /// Swift's `maxEdgesPerMesh: 2_048` default.
    pub fn viewport_wireframe_lines_default(&self) -> Vec<(u64, Float3, Float3)> {
        self.viewport_wireframe_lines(2_048)
    }

    /// Builds a stable, bounded constraint overlay for the selected soft body.
    /// Surface edges are derived from render triangles; an edge participating
    /// in a tetrahedron is marked as a volume edge. Fixed vertices are emitted
    /// separately so the viewport can draw anchors above the line overlay.
    pub fn viewport_soft_body_constraints(
        &self,
        entity_id: u64,
        max_edges: usize,
    ) -> Option<EditorSoftBodyConstraintOverlay> {
        let entity = EntityID::from_raw_value(entity_id);
        self.scene().component::<SoftBody>(entity)?;
        self.with_scene_mut(|scene| {
            if scene.hierarchy_needs_propagation() {
                scene.propagate_transforms();
            }
        });

        let scene = self.scene();
        let cloth = scene.component::<Cloth>(entity);
        let mesh = scene.component::<SoftBodyMesh>(entity);
        if cloth.is_some() == mesh.is_some() {
            return None;
        }

        let authored_positions: Vec<Float3>;
        let triangle_indices: Vec<u32>;
        let tetrahedron_indices: Vec<u32>;
        let fixed_vertex_indices: Vec<i64>;
        if let Some(cloth) = cloth {
            let grid_size_x = cloth.grid_size_x;
            let grid_size_z = cloth.grid_size_z;
            let offset_x = -0.5 * cloth.spacing * (grid_size_x - 1) as f32;
            let offset_z = -0.5 * cloth.spacing * (grid_size_z - 1) as f32;
            authored_positions = (0..grid_size_z)
                .flat_map(|z| {
                    (0..grid_size_x).map(move |x| {
                        Float3::new(
                            offset_x + x as f32 * cloth.spacing,
                            0.0,
                            offset_z + z as f32 * cloth.spacing,
                        )
                    })
                })
                .collect();
            let cell_count = (grid_size_x - 1) * (grid_size_z - 1);
            let sampled_cell_count = if max_edges > 0 {
                cell_count.min((max_edges / 3).max(1) as i64)
            } else {
                0
            };
            let mut sampled_triangles: Vec<u32> =
                Vec::with_capacity(sampled_cell_count.max(0) as usize * 6);
            if sampled_cell_count > 0 {
                let cell_stride = (cell_count / sampled_cell_count).max(1);
                let mut cell = 0;
                while cell < cell_count && sampled_triangles.len() < sampled_cell_count as usize * 6
                {
                    let x = cell % (grid_size_x - 1);
                    let z = cell / (grid_size_x - 1);
                    let top_left = (x + z * grid_size_x) as u32;
                    let bottom_left = (x + (z + 1) * grid_size_x) as u32;
                    let bottom_right = (x + 1 + (z + 1) * grid_size_x) as u32;
                    let top_right = (x + 1 + z * grid_size_x) as u32;
                    sampled_triangles.extend_from_slice(&[
                        top_left,
                        bottom_left,
                        bottom_right,
                        top_left,
                        bottom_right,
                        top_right,
                    ]);
                    cell += cell_stride;
                }
            }
            triangle_indices = sampled_triangles;
            tetrahedron_indices = Vec::new();
            fixed_vertex_indices = cloth.fixed_vertex_indices;
        } else {
            let mesh = mesh?;
            let geometry = scene
                .resource::<MeshColliderGeometryResource>()
                .and_then(|resource| resource.geometry_for(mesh.resource_id.as_deref()).cloned())?;
            authored_positions = geometry.positions;
            triangle_indices = geometry.triangle_indices;
            tetrahedron_indices = geometry.tetrahedron_indices;
            fixed_vertex_indices = mesh.fixed_vertex_indices;
        }

        let simulated_positions = scene
            .soft_body_state_frame()
            .states
            .get(&entity)
            .map(|state| state.positions.clone());
        let uses_simulated_positions = simulated_positions
            .as_ref()
            .is_some_and(|positions| positions.len() == authored_positions.len());
        let positions: Vec<Float3> = if uses_simulated_positions {
            simulated_positions.unwrap_or_default()
        } else {
            let world = scene
                .world_transform(entity)
                .map(|transform| transform.matrix)
                .or_else(|| {
                    scene
                        .local_transform(entity)
                        .map(|transform| transform.matrix)
                })
                .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
            authored_positions
                .iter()
                .map(|position| {
                    let transformed = world * Float4::new(position.x, position.y, position.z, 1.0);
                    Float3::new(transformed.x, transformed.y, transformed.z)
                })
                .collect()
        };

        let edge_key = |a: u32, b: u32| -> u64 {
            let low = a.min(b);
            let high = a.max(b);
            ((low as u64) << 32) | high as u64
        };
        let position_count = u32::try_from(positions.len()).unwrap_or(u32::MAX);
        let edge_limit = max_edges;
        let mut edges: BTreeSet<u64> = BTreeSet::new();
        let mut volume_edges: BTreeSet<u64> = BTreeSet::new();
        let mut tetrahedron_offset = 0;
        while edge_limit > 0
            && edges.len() < edge_limit
            && tetrahedron_offset + 3 < tetrahedron_indices.len()
        {
            let a = tetrahedron_indices[tetrahedron_offset];
            let b = tetrahedron_indices[tetrahedron_offset + 1];
            let c = tetrahedron_indices[tetrahedron_offset + 2];
            let d = tetrahedron_indices[tetrahedron_offset + 3];
            if a < position_count && b < position_count && c < position_count && d < position_count
            {
                for key in [
                    edge_key(a, b),
                    edge_key(a, c),
                    edge_key(a, d),
                    edge_key(b, c),
                    edge_key(b, d),
                    edge_key(c, d),
                ] {
                    if edges.len() >= edge_limit {
                        break;
                    }
                    edges.insert(key);
                    volume_edges.insert(key);
                }
            }
            tetrahedron_offset += 4;
        }

        let mut triangle_offset = 0;
        while edge_limit > 0
            && edges.len() < edge_limit
            && triangle_offset + 2 < triangle_indices.len()
        {
            let a = triangle_indices[triangle_offset];
            let b = triangle_indices[triangle_offset + 1];
            let c = triangle_indices[triangle_offset + 2];
            if a < position_count && b < position_count && c < position_count {
                for key in [edge_key(a, b), edge_key(b, c), edge_key(c, a)] {
                    if edges.len() >= edge_limit {
                        break;
                    }
                    edges.insert(key);
                }
            }
            triangle_offset += 3;
        }

        let lines: Vec<EditorSoftBodyConstraintLine> = edges
            .iter()
            .map(|key| {
                let a = (key >> 32) as u32;
                let b = (*key & 0xffff_ffff) as u32;
                EditorSoftBodyConstraintLine {
                    vertex_a: a,
                    vertex_b: b,
                    position_a: positions[a as usize],
                    position_b: positions[b as usize],
                    kind: if volume_edges.contains(key) {
                        EditorSoftBodyConstraintKind::Volume
                    } else {
                        EditorSoftBodyConstraintKind::Surface
                    },
                }
            })
            .collect();
        let fixed_vertices: Vec<EditorSoftBodyFixedVertexMarker> = fixed_vertex_indices
            .iter()
            .take(4_096)
            .filter_map(|index| {
                let index = usize::try_from(*index).ok()?;
                if index >= positions.len() {
                    return None;
                }
                Some(EditorSoftBodyFixedVertexMarker {
                    vertex: index as u32,
                    position: positions[index],
                })
            })
            .collect();
        Some(EditorSoftBodyConstraintOverlay {
            lines,
            fixed_vertices,
            uses_simulated_positions,
        })
    }

    /// Swift's `maxEdges: 4_096` default.
    pub fn viewport_soft_body_constraints_default(
        &self,
        entity_id: u64,
    ) -> Option<EditorSoftBodyConstraintOverlay> {
        self.viewport_soft_body_constraints(entity_id, 4_096)
    }

    /// Returns the selected destructible's stable connection graph from the unified
    /// physics debug frame. The viewport colors intact and broken edges separately.
    pub fn viewport_destruction_connections(
        &self,
        entity_id: u64,
        max_connections: usize,
    ) -> Vec<EditorDestructionConnectionLine> {
        let entity = EntityID::from_raw_value(entity_id);
        let scene = self.scene();
        if scene.component::<Destructible>(entity).is_none() {
            return Vec::new();
        }
        scene
            .physics_debug_frame()
            .destruction_connections
            .iter()
            .filter(|connection| connection.source_entity == entity)
            .take(max_connections)
            .map(|connection| EditorDestructionConnectionLine {
                connection_id: connection.connection_id,
                fragment_a: connection.fragment_a,
                fragment_b: connection.fragment_b,
                position_a: connection.world_point_a,
                position_b: connection.world_point_b,
                is_broken: connection.is_broken,
                is_source_fractured: connection.is_source_fractured,
            })
            .collect()
    }

    /// Swift's `maxConnections: 4_096` default.
    pub fn viewport_destruction_connections_default(
        &self,
        entity_id: u64,
    ) -> Vec<EditorDestructionConnectionLine> {
        self.viewport_destruction_connections(entity_id, 4_096)
    }

    /// Builds either a selected-entity or scene-wide physics overlay from the unified runtime
    /// debug frame. Disabled categories never consume the stable line/contact budgets.
    pub fn viewport_physics_debug_overlay(
        &self,
        entity_id: Option<u64>,
        options: EditorPhysicsDebugOverlayOptions,
        max_lines: usize,
        max_contacts: usize,
    ) -> EditorPhysicsDebugOverlay {
        let selected_entity = entity_id.map(EntityID::from_raw_value);
        let frame = self.scene().physics_debug_frame();
        let line_limit = max_lines;
        let mut lines: Vec<EditorPhysicsDebugLine> = Vec::with_capacity(line_limit.min(512));
        let mut sleeping_body_entity_ids: BTreeSet<u64> = BTreeSet::new();
        let mut trigger_body_entity_ids: BTreeSet<u64> = BTreeSet::new();
        let mut grounded_character_entity_ids: BTreeSet<u64> = BTreeSet::new();

        let selected_body = selected_entity
            .and_then(|selected| frame.bodies.iter().find(|body| body.entity == selected));
        for body in &frame.bodies {
            if selected_entity.is_some_and(|selected| body.entity != selected) {
                continue;
            }
            let body_id = body.entity.raw_value();
            if body.is_sleeping {
                sleeping_body_entity_ids.insert(body_id);
            }
            if body.is_trigger {
                trigger_body_entity_ids.insert(body_id);
            }
            if options.contains(EditorPhysicsDebugOverlayOptions::BOUNDS)
                && lines.len() < line_limit
            {
                append_aabb_lines(
                    &body.bounds,
                    body_id,
                    EditorPhysicsDebugLineKind::Bounds,
                    &mut lines,
                    line_limit,
                );
            }
            if options.contains(EditorPhysicsDebugOverlayOptions::SHAPES) {
                for instance in &body.shapes {
                    if lines.len() >= line_limit {
                        break;
                    }
                    self.append_collider_shape_lines(
                        instance,
                        body.world_transform.matrix,
                        body_id,
                        &mut lines,
                        line_limit,
                    );
                }
            }
        }

        if options.contains(EditorPhysicsDebugOverlayOptions::JOINTS) {
            for joint in &frame.constraints {
                if lines.len() >= line_limit {
                    break;
                }
                if let Some(selected) = selected_entity
                    && joint.entity != selected
                    && joint.entity_a != selected
                    && joint.entity_b != selected
                {
                    continue;
                }
                self.append_joint_lines(joint, &mut lines, line_limit);
            }
        }

        let selected_character = selected_entity.and_then(|selected| {
            frame
                .characters
                .iter()
                .find(|character| character.entity == selected)
        });
        if options.contains(EditorPhysicsDebugOverlayOptions::CHARACTERS) {
            for character in &frame.characters {
                if lines.len() >= line_limit {
                    break;
                }
                if selected_entity.is_some_and(|selected| character.entity != selected) {
                    continue;
                }
                if simd_length_squared(character.ground_normal) <= 1e-8 {
                    continue;
                }
                if character.ground_state == CharacterGroundState::OnGround {
                    grounded_character_entity_ids.insert(character.entity.raw_value());
                }
                let normal = simd_normalize(character.ground_normal);
                lines.push(EditorPhysicsDebugLine {
                    entity_id: character.entity.raw_value(),
                    position_a: character.position,
                    position_b: character.position + normal * 0.8,
                    kind: EditorPhysicsDebugLineKind::CharacterGround,
                });
            }
        }

        let contacts: Vec<EditorPhysicsContactMarker> = if options
            .contains(EditorPhysicsDebugOverlayOptions::CONTACTS)
        {
            frame
                .contacts
                .iter()
                .filter(|contact| match selected_entity {
                    Some(selected) => contact.entity_a == selected || contact.entity_b == selected,
                    None => true,
                })
                .take(max_contacts)
                .map(|contact| {
                    let normal = if simd_length_squared(contact.normal) > 1e-8 {
                        simd_normalize(contact.normal)
                    } else {
                        Float3::new(0.0, 1.0, 0.0)
                    };
                    EditorPhysicsContactMarker {
                        entity_a: contact.entity_a.raw_value(),
                        entity_b: contact.entity_b.raw_value(),
                        position: contact.position,
                        normal_end: contact.position + normal * contact.penetration_depth.max(0.25),
                        kind: contact.kind,
                        penetration_depth: contact.penetration_depth,
                        impulse: contact.impulse,
                    }
                })
                .collect()
        } else {
            Vec::new()
        };

        EditorPhysicsDebugOverlay {
            lines,
            contacts,
            sleeping_body_entity_ids,
            trigger_body_entity_ids,
            grounded_character_entity_ids,
            selected_body_is_sleeping: selected_body.map(|body| body.is_sleeping).unwrap_or(false),
            selected_body_is_trigger: selected_body.map(|body| body.is_trigger).unwrap_or(false),
            character_ground_state: selected_character.map(|character| character.ground_state),
        }
    }

    /// Swift's all-defaults form: scene-wide scope, every category, 8 192 lines
    /// and 512 contacts.
    pub fn viewport_physics_debug_overlay_default(&self) -> EditorPhysicsDebugOverlay {
        self.viewport_physics_debug_overlay(
            None,
            EditorPhysicsDebugOverlayOptions::all(),
            8_192,
            512,
        )
    }

    fn append_collider_shape_lines(
        &self,
        instance: &ColliderShapeInstance,
        body_transform: Float4x4,
        entity_id: u64,
        lines: &mut Vec<EditorPhysicsDebugLine>,
        limit: usize,
    ) {
        let transform = body_transform * collider_instance_matrix(instance);
        let local_limit = limit.saturating_sub(lines.len());
        let mut local_lines: Vec<EditorPhysicsDebugLine> = Vec::with_capacity(local_limit.min(96));
        {
            let mut append_local_line = |a: Float3, b: Float3| {
                if local_lines.len() >= local_limit {
                    return;
                }
                let wa = transform * Float4::new(a.x, a.y, a.z, 1.0);
                let wb = transform * Float4::new(b.x, b.y, b.z, 1.0);
                local_lines.push(EditorPhysicsDebugLine {
                    entity_id,
                    position_a: Float3::new(wa.x, wa.y, wa.z),
                    position_b: Float3::new(wb.x, wb.y, wb.z),
                    kind: EditorPhysicsDebugLineKind::Collider,
                });
            };

            match &instance.shape {
                ColliderShape::Box {
                    half_extents,
                    center,
                } => {
                    append_box_lines(*center, *half_extents, &mut append_local_line);
                }
                ColliderShape::Sphere { radius, center } => {
                    append_ring_lines(*center, *radius, (0, 1), &mut append_local_line);
                    append_ring_lines(*center, *radius, (0, 2), &mut append_local_line);
                    append_ring_lines(*center, *radius, (1, 2), &mut append_local_line);
                }
                ColliderShape::Capsule {
                    radius,
                    half_height,
                    center,
                } => {
                    let top = *center + Float3::new(0.0, *half_height, 0.0);
                    let bottom = *center - Float3::new(0.0, *half_height, 0.0);
                    append_ring_lines(top, *radius, (0, 2), &mut append_local_line);
                    append_ring_lines(bottom, *radius, (0, 2), &mut append_local_line);
                    for direction in [
                        Float3::new(1.0, 0.0, 0.0),
                        Float3::new(-1.0, 0.0, 0.0),
                        Float3::new(0.0, 0.0, 1.0),
                        Float3::new(0.0, 0.0, -1.0),
                    ] {
                        append_local_line(bottom + direction * *radius, top + direction * *radius);
                    }
                    append_capsule_arc_lines(
                        *center,
                        *radius,
                        *half_height,
                        0,
                        &mut append_local_line,
                    );
                    append_capsule_arc_lines(
                        *center,
                        *radius,
                        *half_height,
                        2,
                        &mut append_local_line,
                    );
                }
                ColliderShape::Cylinder {
                    radius,
                    half_height,
                    center,
                } => {
                    let top = *center + Float3::new(0.0, *half_height, 0.0);
                    let bottom = *center - Float3::new(0.0, *half_height, 0.0);
                    append_ring_lines(top, *radius, (0, 2), &mut append_local_line);
                    append_ring_lines(bottom, *radius, (0, 2), &mut append_local_line);
                    for direction in [
                        Float3::new(1.0, 0.0, 0.0),
                        Float3::new(-1.0, 0.0, 0.0),
                        Float3::new(0.0, 0.0, 1.0),
                        Float3::new(0.0, 0.0, -1.0),
                    ] {
                        append_local_line(bottom + direction * *radius, top + direction * *radius);
                    }
                }
                // Resource-backed shapes use their authoritative physics AABB above.
                ColliderShape::HeightField { .. }
                | ColliderShape::Mesh { .. }
                | ColliderShape::Convex { .. } => {}
            }
        }
        lines.extend(local_lines);
    }

    fn append_joint_lines(
        &self,
        joint: &PhysicsDebugConstraint,
        lines: &mut Vec<EditorPhysicsDebugLine>,
        limit: usize,
    ) {
        let scene = self.scene();
        let matrix_a = scene
            .world_transform(joint.entity_a)
            .map(|transform| transform.matrix)
            .or_else(|| {
                scene
                    .local_transform(joint.entity_a)
                    .map(|transform| transform.matrix)
            })
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
        let matrix_b = scene
            .world_transform(joint.entity_b)
            .map(|transform| transform.matrix)
            .or_else(|| {
                scene
                    .local_transform(joint.entity_b)
                    .map(|transform| transform.matrix)
            })
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
        let anchor_a4 =
            matrix_a * Float4::new(joint.pivot_a.x, joint.pivot_a.y, joint.pivot_a.z, 1.0);
        let anchor_b4 =
            matrix_b * Float4::new(joint.pivot_b.x, joint.pivot_b.y, joint.pivot_b.z, 1.0);
        let anchor_a = Float3::new(anchor_a4.x, anchor_a4.y, anchor_a4.z);
        let anchor_b = Float3::new(anchor_b4.x, anchor_b4.y, anchor_b4.z);
        let axis_a4 = matrix_a * Float4::new(joint.axis_a.x, joint.axis_a.y, joint.axis_a.z, 0.0);
        let axis_b4 = matrix_b * Float4::new(joint.axis_b.x, joint.axis_b.y, joint.axis_b.z, 0.0);
        let axis_a_value = Float3::new(axis_a4.x, axis_a4.y, axis_a4.z);
        let axis_b_value = Float3::new(axis_b4.x, axis_b4.y, axis_b4.z);
        let axis_a = if simd_length_squared(axis_a_value) > 1e-8 {
            simd_normalize(axis_a_value)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let axis_b = if simd_length_squared(axis_b_value) > 1e-8 {
            simd_normalize(axis_b_value)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let entity_id = joint.entity.raw_value();

        append_joint_line(
            lines,
            limit,
            entity_id,
            anchor_a,
            anchor_b,
            EditorPhysicsDebugLineKind::Joint,
        );
        append_joint_line(
            lines,
            limit,
            entity_id,
            anchor_a,
            anchor_a + axis_a * 0.6,
            EditorPhysicsDebugLineKind::JointAxis,
        );
        append_joint_line(
            lines,
            limit,
            entity_id,
            anchor_b,
            anchor_b + axis_b * 0.6,
            EditorPhysicsDebugLineKind::JointAxis,
        );

        let helper = if axis_a.y.abs() < 0.9 {
            Float3::new(0.0, 1.0, 0.0)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let basis_y = simd_normalize(simd_cross(axis_a, helper));
        let basis_z = simd_normalize(simd_cross(axis_a, basis_y));

        match &joint.configuration {
            PhysicsJointConfiguration::Point | PhysicsJointConfiguration::Fixed { .. } => {}
            PhysicsJointConfiguration::Distance(configuration) => {
                append_joint_line(
                    lines,
                    limit,
                    entity_id,
                    anchor_a + axis_a * configuration.minimum_distance,
                    anchor_a + axis_a * configuration.maximum_distance,
                    EditorPhysicsDebugLineKind::JointLimit,
                );
            }
            PhysicsJointConfiguration::Slider(configuration) => {
                append_joint_line(
                    lines,
                    limit,
                    entity_id,
                    anchor_a + axis_a * configuration.minimum_distance,
                    anchor_a + axis_a * configuration.maximum_distance,
                    EditorPhysicsDebugLineKind::JointLimit,
                );
            }
            PhysicsJointConfiguration::Hinge(configuration) => {
                append_joint_angular_limit(
                    lines,
                    limit,
                    entity_id,
                    anchor_a,
                    axis_a,
                    basis_y,
                    configuration.minimum_angle,
                    configuration.maximum_angle,
                    0.5,
                );
            }
            PhysicsJointConfiguration::Cone(configuration) => {
                append_joint_angular_limit(
                    lines,
                    limit,
                    entity_id,
                    anchor_a,
                    axis_a,
                    basis_y,
                    configuration.minimum_twist_angle,
                    configuration.maximum_twist_angle,
                    0.5,
                );
                let length: f32 = 0.65;
                let axial = configuration.half_cone_angle.cos() * length;
                let radial = configuration.half_cone_angle.sin() * length;
                let segment_count = 16;
                let mut first: Option<Float3> = None;
                let mut previous: Option<Float3> = None;
                for segment in 0..segment_count {
                    if lines.len() >= limit {
                        continue;
                    }
                    let angle = segment as f32 * 2.0 * PI / segment_count as f32;
                    let rim = anchor_a
                        + axis_a * axial
                        + basis_y * (angle.cos() * radial)
                        + basis_z * (angle.sin() * radial);
                    if segment % 4 == 0 {
                        append_joint_line(
                            lines,
                            limit,
                            entity_id,
                            anchor_a,
                            rim,
                            EditorPhysicsDebugLineKind::JointLimit,
                        );
                    }
                    if let Some(previous) = previous {
                        append_joint_line(
                            lines,
                            limit,
                            entity_id,
                            previous,
                            rim,
                            EditorPhysicsDebugLineKind::JointLimit,
                        );
                    }
                    if first.is_none() {
                        first = Some(rim);
                    }
                    previous = Some(rim);
                }
                if let (Some(first), Some(previous)) = (first, previous) {
                    append_joint_line(
                        lines,
                        limit,
                        entity_id,
                        previous,
                        first,
                        EditorPhysicsDebugLineKind::JointLimit,
                    );
                }
            }
            PhysicsJointConfiguration::SixDof(configuration) => {
                let minimum = configuration.linear_minimum;
                let maximum = configuration.linear_maximum;
                let linear_limit_point = |x: f32, y: f32, z: f32| -> Float3 {
                    anchor_a + axis_a * x + basis_y * y + basis_z * z
                };
                let corners = [
                    linear_limit_point(minimum.x, minimum.y, minimum.z),
                    linear_limit_point(maximum.x, minimum.y, minimum.z),
                    linear_limit_point(maximum.x, maximum.y, minimum.z),
                    linear_limit_point(minimum.x, maximum.y, minimum.z),
                    linear_limit_point(minimum.x, minimum.y, maximum.z),
                    linear_limit_point(maximum.x, minimum.y, maximum.z),
                    linear_limit_point(maximum.x, maximum.y, maximum.z),
                    linear_limit_point(minimum.x, maximum.y, maximum.z),
                ];
                for (a, b) in [
                    (0, 1),
                    (1, 2),
                    (2, 3),
                    (3, 0),
                    (4, 5),
                    (5, 6),
                    (6, 7),
                    (7, 4),
                    (0, 4),
                    (1, 5),
                    (2, 6),
                    (3, 7),
                ] {
                    if lines.len() >= limit {
                        continue;
                    }
                    append_joint_line(
                        lines,
                        limit,
                        entity_id,
                        corners[a],
                        corners[b],
                        EditorPhysicsDebugLineKind::JointLimit,
                    );
                }
                append_joint_angular_limit(
                    lines,
                    limit,
                    entity_id,
                    anchor_a,
                    axis_a,
                    basis_y,
                    configuration.angular_minimum.x,
                    configuration.angular_maximum.x,
                    0.45,
                );
                append_joint_angular_limit(
                    lines,
                    limit,
                    entity_id,
                    anchor_a,
                    basis_y,
                    basis_z,
                    configuration.angular_minimum.y,
                    configuration.angular_maximum.y,
                    0.4,
                );
                append_joint_angular_limit(
                    lines,
                    limit,
                    entity_id,
                    anchor_a,
                    basis_z,
                    axis_a,
                    configuration.angular_minimum.z,
                    configuration.angular_maximum.z,
                    0.35,
                );
            }
        }
    }

    fn viewport_ray(
        &self,
        cursor_x: f32,
        cursor_y: f32,
        frame: ViewportScreenFrame,
    ) -> Option<ViewportRay> {
        let projection = EditorViewportProjection::new(self.current_render_camera(), frame)?;
        let (origin, direction) = projection.cursor_ray(cursor_x, cursor_y);
        Some(ViewportRay { origin, direction })
    }

    fn project_to_viewport(&self, world: Float3, frame: ViewportScreenFrame) -> Option<(f32, f32)> {
        EditorViewportProjection::new(self.current_render_camera(), frame)?.project_default(world)
    }

    // MARK: - Selection helpers

    /// Fits the selected entity and all of its rendered descendants while
    /// preserving the current viewing direction. Non-rendered entities fall
    /// back to a small world-space box around their transform origin.
    ///
    /// Swift's `viewportAspectRatio: nil` default is
    /// [`Self::frame_entity_default`].
    pub fn frame_entity(&self, entity_id: u64, viewport_aspect_ratio: Option<f32>) {
        self.frame_entities(&BTreeSet::from([entity_id]), viewport_aspect_ratio);
    }

    /// Swift's `viewportAspectRatio: nil` default.
    pub fn frame_entity_default(&self, entity_id: u64) {
        self.frame_entity(entity_id, None);
    }

    /// Fits a complete selection, including each selected entity's rendered
    /// descendants, without changing authored cameras or the undo history.
    pub fn frame_entities(&self, entity_ids: &BTreeSet<u64>, viewport_aspect_ratio: Option<f32>) {
        let centers_by_id: BTreeMap<u64, Float3> = entity_ids
            .iter()
            .filter_map(|entity_id| {
                self.entity_world_position(*entity_id)
                    .map(|position| (*entity_id, position))
            })
            .collect();
        if centers_by_id.is_empty() {
            return;
        }
        let camera = self.editor_viewport_camera.get();

        let selection_ids: BTreeSet<u64> = centers_by_id.keys().copied().collect();
        let relevant_bounds = self.viewport_world_bounds().into_iter().filter(|bounds| {
            selection_ids.contains(&bounds.0) || self.entity_has_ancestor(bounds.0, &selection_ids)
        });
        let mut lower = Float3::splat(f32::MAX);
        let mut upper = Float3::splat(-f32::MAX);
        let mut included_ids: BTreeSet<u64> = BTreeSet::new();
        for bounds in relevant_bounds {
            if !is_finite_vector(bounds.1) || !is_finite_vector(bounds.2) {
                continue;
            }
            lower = simd_min(lower, simd_min(bounds.1, bounds.2));
            upper = simd_max(upper, simd_max(bounds.1, bounds.2));
            included_ids.insert(bounds.0);
        }
        for (entity_id, center) in &centers_by_id {
            if included_ids.contains(entity_id) {
                continue;
            }
            let half_size = Float3::splat(0.25);
            lower = simd_min(lower, *center - half_size);
            upper = simd_max(upper, *center + half_size);
        }
        let pose = EditorViewportFraming::pose(&camera, lower, upper, viewport_aspect_ratio, 1.3);
        self.set_editor_camera_pose(
            pose.eye,
            pose.target,
            Some(pose.up),
            None,
            pose.orthographic_height,
        );
    }

    /// Swift's `viewportAspectRatio: nil` default.
    pub fn frame_entities_default(&self, entity_ids: &BTreeSet<u64>) {
        self.frame_entities(entity_ids, None);
    }

    // MARK: - Entity ops

    /// 直接销毁实体；选择状态由调用方负责清理。
    pub fn delete_entity(&self, entity_id: u64) -> bool {
        self.delete_entities(&BTreeSet::from([entity_id]))
    }

    /// Deletes the complete editor selection as one transaction so a multi-select
    /// Delete is atomic and can be restored with a single Undo.
    pub fn delete_entities(&self, entity_ids: &BTreeSet<u64>) -> bool {
        let entity_ids: Vec<u64> = entity_ids.iter().copied().collect();
        if entity_ids.is_empty() {
            return false;
        }
        let scene = self.scene();
        if !entity_ids.iter().all(|entity_id| {
            make_entity_id(*entity_id).map(|entity| scene.contains(entity)) == Some(true)
        }) {
            return false;
        }
        // RuntimeWorld intentionally promotes children to roots when their
        // parent is destroyed. Every explicitly selected entity must therefore
        // receive its own delete mutation. Delete descendants first so the
        // transaction never depends on that promotion side effect and remains
        // deterministic for mixed ancestor/descendant selections.
        let mut deletion_order = entity_ids.clone();
        deletion_order.sort_by(|lhs, rhs| {
            if self.entity_has_ancestor(*lhs, &BTreeSet::from([*rhs])) {
                return Ordering::Less;
            }
            if self.entity_has_ancestor(*rhs, &BTreeSet::from([*lhs])) {
                return Ordering::Greater;
            }
            lhs.cmp(rhs)
        });
        self.apply_scene_transaction(
            "scene.delete_entities",
            if entity_ids.len() == 1 {
                "Delete entity"
            } else {
                "Delete entities"
            },
            entity_ids.clone(),
            deletion_order
                .iter()
                .map(|entity_id| SceneMutation::DeleteEntity {
                    entity_id: *entity_id,
                })
                .collect(),
        )
        .is_some()
    }

    /// 浅复制：复制名字 / kind / 本地矩阵 / 渲染网格 / collider / rigid body / camera。
    /// 不复制子节点；新实体附在原父节点下。返回新实体 raw ID。
    pub fn duplicate_entity(&self, entity_id: u64) -> Option<u64> {
        self.duplicate_entities(&BTreeSet::from([entity_id]))
            .and_then(|created| created.first().copied())
    }

    /// Duplicates a hierarchy selection atomically. The returned identifiers
    /// follow the deterministic source-ID order and can replace the selection
    /// immediately after the transaction commits.
    pub fn duplicate_entities(&self, entity_ids: &BTreeSet<u64>) -> Option<Vec<u64>> {
        let entity_ids: Vec<u64> = entity_ids.iter().copied().collect();
        if entity_ids.is_empty() {
            return None;
        }
        let scene = self.scene();
        if !entity_ids.iter().all(|entity_id| {
            make_entity_id(*entity_id).map(|entity| scene.contains(entity)) == Some(true)
        }) {
            return None;
        }
        let result = self.apply_scene_transaction(
            "scene.duplicate_entity",
            if entity_ids.len() == 1 {
                "Duplicate entity"
            } else {
                "Duplicate entities"
            },
            entity_ids.clone(),
            entity_ids
                .iter()
                .map(|entity_id| SceneMutation::DuplicateEntity {
                    entity_id: *entity_id,
                })
                .collect(),
        );
        result.map(|result| result.created_entity_ids)
    }

    // MARK: - Camera control

    pub fn reset_viewport_view(&self) {
        let camera = Self::default_viewport_camera();
        self.set_editor_camera_pose(
            camera.eye,
            camera.target,
            Some(camera.up),
            Some(camera.projection),
            Some(camera.orthographic_height),
        );
    }

    /// Switch projection without changing the apparent scale at the focus plane.
    pub fn set_viewport_projection(&self, projection: RenderCameraProjection) {
        if !self.is_authoring_enabled() {
            return;
        }
        let camera = self.editor_viewport_camera.get();
        if camera.projection == projection {
            return;
        }
        let distance = simd_length(camera.eye - camera.target).max(0.2);
        let tan_half_fov = (camera.fov_y_radians * 0.5).tan().max(0.01);
        if projection == RenderCameraProjection::Orthographic {
            self.set_editor_camera_pose(
                camera.eye,
                camera.target,
                None,
                Some(projection),
                Some(distance * 2.0 * tan_half_fov),
            );
        } else {
            let backward = simd_normalize(camera.eye - camera.target);
            let new_distance = (camera.orthographic_height / (2.0 * tan_half_fov)).max(0.2);
            self.set_editor_camera_pose(
                camera.target + backward * new_distance,
                camera.target,
                None,
                Some(projection),
                None,
            );
        }
    }

    /// 用屏幕像素 delta 控制编辑器相机绕 target 球面旋转。
    /// 与旧 Editor backend 一致：delta 直接乘 `orbit_sensitivity = 0.01`。
    pub fn orbit_camera(
        &self,
        delta_screen_x: f32,
        delta_screen_y: f32,
        frame: ViewportScreenFrame,
    ) {
        let camera = self.editor_viewport_camera.get();
        let forward_raw = camera.target - camera.eye;
        let distance = simd_length(forward_raw);
        if distance <= 1e-4 {
            return;
        }

        let forward = forward_raw / distance;
        let mut yaw = forward.x.atan2(forward.z);
        let mut pitch = forward.y.clamp(-1.0, 1.0).asin();
        yaw -= delta_screen_x * 0.01;
        pitch = clamp_pitch(pitch - delta_screen_y * 0.01);

        let next_forward = forward_from_angles(yaw, pitch);
        let new_eye = camera.target - next_forward * distance;
        self.set_editor_camera_pose(
            new_eye,
            camera.target,
            Some(Float3::new(0.0, 1.0, 0.0)),
            None,
            None,
        );
        let _ = frame;
    }

    /// 在相机右 / 上方向上平移 eye 与 target，保持视线方向不变。
    /// 正交视图按可见高度换算像素；透视视图随焦点距离调整平移速度。
    pub fn pan_camera(&self, delta_screen_x: f32, delta_screen_y: f32, frame: ViewportScreenFrame) {
        let camera = self.editor_viewport_camera.get();
        let forward = simd_normalize(camera.target - camera.eye);
        let right_raw = simd_cross(forward, camera.up);
        if simd_length(right_raw) <= 1e-5 {
            return;
        }
        let right = simd_normalize(right_raw);
        let up = simd_normalize(simd_cross(right, forward));
        let distance = simd_length(camera.eye - camera.target).max(0.5);
        let (factor_x, factor_y) = pan_speed_factors(frame.width, frame.height);
        let translation = if camera.projection == RenderCameraProjection::Orthographic {
            let units_per_pixel = camera.orthographic_height / frame.height.max(1.0);
            -right * (delta_screen_x * units_per_pixel) + up * (delta_screen_y * units_per_pixel)
        } else {
            -right * (delta_screen_x * factor_x * distance * 0.01)
                + up * (delta_screen_y * factor_y * distance * 0.01)
        };
        let new_eye = camera.eye + translation;
        let new_target = camera.target + translation;
        self.set_editor_camera_pose(new_eye, new_target, None, None, None);
    }

    /// Alt+RMB dolly adjusts orthographic extent or perspective eye distance.
    pub fn dolly_camera(&self, delta_screen_y: f32) {
        let camera = self.editor_viewport_camera.get();
        if camera.projection == RenderCameraProjection::Orthographic {
            self.zoom_camera((delta_screen_y * 0.01).clamp(-4.0, 4.0).exp());
            return;
        }
        let forward_raw = camera.target - camera.eye;
        let distance = simd_length(forward_raw);
        if distance <= 1e-4 {
            return;
        }
        let forward = forward_raw / distance;
        let step = -delta_screen_y * 1.2 * 0.01 * zoom_speed(distance);
        let new_distance = (distance - step).clamp(0.2, 500.0);
        let new_eye = camera.target - forward * new_distance;
        self.set_editor_camera_pose(new_eye, camera.target, None, None, None);
    }

    /// RMB freelook: rotate around the eye and optionally move with WASDQE.
    ///
    /// Swift's `deltaTime: 1.0 / 60.0` default is
    /// [`Self::freelook_camera_default`].
    pub fn freelook_camera(
        &self,
        delta_screen_x: f32,
        delta_screen_y: f32,
        pressed_scancodes: &BTreeSet<u32>,
        modifiers: KeyModifiers,
        delta_time: f32,
    ) {
        let camera = self.editor_viewport_camera.get();
        let forward = camera.target - camera.eye;
        let focus_distance = simd_length(forward).max(0.5);
        if focus_distance <= 1e-4 {
            return;
        }
        let forward = simd_normalize(forward);

        let world_up = Float3::new(0.0, 1.0, 0.0);
        let yaw = Quatf::from_angle_axis(-delta_screen_x * 0.008, world_up);
        let mut right = simd_cross(forward, camera.up);
        if simd_length(right) < 1e-5 {
            right = simd_cross(forward, world_up);
        }
        right = simd_normalize(right);
        let pitch = Quatf::from_angle_axis(-delta_screen_y * 0.008, right);
        let mut next_forward = simd_normalize(yaw.act(pitch.act(forward)));
        if simd_dot(next_forward, world_up).abs() > 0.985 {
            next_forward = simd_normalize(yaw.act(forward));
        }
        let reference_up = if simd_dot(next_forward, world_up).abs() > 0.985 {
            camera.up
        } else {
            world_up
        };
        right = simd_normalize(simd_cross(next_forward, reference_up));
        let up = simd_normalize(simd_cross(right, next_forward));

        let mut movement = Float3::ZERO;
        // W
        if pressed_scancodes.contains(&26) {
            movement += next_forward;
        }
        // S
        if pressed_scancodes.contains(&22) {
            movement -= next_forward;
        }
        // D
        if pressed_scancodes.contains(&7) {
            movement += right;
        }
        // A
        if pressed_scancodes.contains(&4) {
            movement -= right;
        }
        // E
        if pressed_scancodes.contains(&8) {
            movement += up;
        }
        // Q
        if pressed_scancodes.contains(&20) {
            movement -= up;
        }
        let boost: f32 = if modifiers.has_shift() { 3.5 } else { 1.0 };
        let speed: f32 = 6.0 * boost * delta_time.max(1.0 / 240.0);
        let translation = if simd_length(movement) > 1e-5 {
            simd_normalize(movement) * speed
        } else {
            Float3::ZERO
        };

        let new_eye = camera.eye + translation;
        let new_target = new_eye + next_forward * focus_distance;
        self.set_editor_camera_pose(new_eye, new_target, Some(up), None, None);
    }

    /// Swift's `deltaTime: 1.0 / 60.0` default.
    pub fn freelook_camera_default(
        &self,
        delta_screen_x: f32,
        delta_screen_y: f32,
        pressed_scancodes: &BTreeSet<u32>,
        modifiers: KeyModifiers,
    ) {
        self.freelook_camera(
            delta_screen_x,
            delta_screen_y,
            pressed_scancodes,
            modifiers,
            1.0 / 60.0,
        );
    }

    /// 滚轮缩放：factor < 1 拉近，> 1 推远。正交模式调整可见高度。
    pub fn zoom_camera(&self, factor: f32) {
        let camera = self.editor_viewport_camera.get();
        if !factor.is_finite() || factor <= 0.0 {
            return;
        }
        if camera.projection == RenderCameraProjection::Orthographic {
            self.set_editor_camera_pose(
                camera.eye,
                camera.target,
                None,
                None,
                Some(camera.orthographic_height * factor),
            );
            return;
        }
        let offset = camera.eye - camera.target;
        let radius = simd_length(offset);
        if radius < 1e-4 {
            return;
        }
        let new_radius = (radius * factor).clamp(0.2, 500.0);
        let new_eye = camera.target + simd_normalize(offset) * new_radius;
        self.set_editor_camera_pose(new_eye, camera.target, None, None, None);
    }

    /// ViewCube axis snap. `axis` is the desired camera forward direction in world space.
    ///
    /// Swift's `orthographic: false` default is [`Self::look_along_axis_default`].
    pub fn look_along_axis(&self, axis: Float3, orthographic: bool) {
        if !self.is_authoring_enabled() {
            return;
        }
        if orthographic {
            self.set_viewport_projection(RenderCameraProjection::Orthographic);
        }
        let camera = self.editor_viewport_camera.get();
        let length = simd_length(axis);
        if length <= 1e-5 {
            return;
        }
        let forward = axis / length;
        let distance = simd_length(camera.eye - camera.target).max(0.5);
        let new_eye = camera.target - forward * distance;
        let up = view_up(forward);
        self.set_editor_camera_pose(new_eye, camera.target, Some(up), None, None);
    }

    /// Swift's `orthographic: false` default.
    pub fn look_along_axis_default(&self, axis: Float3) {
        self.look_along_axis(axis, false);
    }

    // MARK: - Internal

    fn set_editor_camera_pose(
        &self,
        eye: Float3,
        target: Float3,
        up: Option<Float3>,
        projection: Option<RenderCameraProjection>,
        orthographic_height: Option<f32>,
    ) {
        if !self.is_authoring_enabled() {
            return;
        }
        let mut camera = self.editor_viewport_camera.get();
        camera.eye = eye;
        camera.target = target;
        if let Some(up) = up {
            camera.up = up;
        }
        if let Some(projection) = projection {
            camera.projection = projection;
        }
        if let Some(orthographic_height) = orthographic_height {
            camera.orthographic_height =
                RenderCamera::sanitized_orthographic_height(orthographic_height);
        }
        self.editor_viewport_camera.set(camera);
        if self.uses_editor_viewport_camera() {
            if let Some(handler) = self.on_viewport_camera_changed.borrow().clone() {
                handler();
            }
        } else {
            self.set_editor_viewport_camera_enabled(true);
        }
    }
}

fn make_entity_id(raw_id: u64) -> Option<EntityID> {
    Some(EntityID::from_raw_value(raw_id))
}

fn is_finite_vector(vector: Float3) -> bool {
    vector.x.is_finite() && vector.y.is_finite() && vector.z.is_finite()
}

fn view_up(forward: Float3) -> Float3 {
    let world_up = Float3::new(0.0, 1.0, 0.0);
    if simd_dot(forward, world_up).abs() < 0.92 {
        return world_up;
    }
    if forward.y < 0.0 {
        Float3::new(0.0, 0.0, -1.0)
    } else {
        Float3::new(0.0, 0.0, 1.0)
    }
}

fn clamp_pitch(value: f32) -> f32 {
    (-PI * 0.5 + 0.05).max((PI * 0.5 - 0.05).min(value))
}

fn forward_from_angles(yaw: f32, pitch: f32) -> Float3 {
    let cosine_pitch = pitch.cos();
    simd_normalize(Float3::new(
        yaw.sin() * cosine_pitch,
        pitch.sin(),
        yaw.cos() * cosine_pitch,
    ))
}

fn pan_speed_factors(width: f32, height: f32) -> (f32, f32) {
    let width_k = (width / 1000.0).min(2.4);
    let height_k = (height / 1000.0).min(2.4);
    (
        0.0366 * width_k * width_k - 0.1778 * width_k + 0.3021,
        0.0366 * height_k * height_k - 0.1778 * height_k + 0.3021,
    )
}

fn zoom_speed(distance: f32) -> f32 {
    let scaled = (distance * 0.2).max(0.0);
    (scaled * scaled).min(100.0)
}

fn collider_instance_matrix(instance: &ColliderShapeInstance) -> Float4x4 {
    let mut translation = MATRIX_IDENTITY_FLOAT4X4;
    translation.set_column(
        3,
        Float4::new(
            instance.local_position.x,
            instance.local_position.y,
            instance.local_position.z,
            1.0,
        ),
    );
    let rotation_vector = instance.local_rotation;
    let length_squared = simd_length_squared4(rotation_vector);
    let normalized_rotation = if length_squared > 1e-8 {
        rotation_vector / length_squared.sqrt()
    } else {
        Float4::new(0.0, 0.0, 0.0, 1.0)
    };
    let rotation = Float4x4::from_quatf(Quatf::from_vector(normalized_rotation));
    let mut scale = MATRIX_IDENTITY_FLOAT4X4;
    scale.columns[0].x = instance.local_scale.x;
    scale.columns[1].y = instance.local_scale.y;
    scale.columns[2].z = instance.local_scale.z;
    translation * rotation * scale
}

fn append_box_lines(center: Float3, half_extents: Float3, append: &mut dyn FnMut(Float3, Float3)) {
    let corners = [
        center + Float3::new(-half_extents.x, -half_extents.y, -half_extents.z),
        center + Float3::new(half_extents.x, -half_extents.y, -half_extents.z),
        center + Float3::new(half_extents.x, half_extents.y, -half_extents.z),
        center + Float3::new(-half_extents.x, half_extents.y, -half_extents.z),
        center + Float3::new(-half_extents.x, -half_extents.y, half_extents.z),
        center + Float3::new(half_extents.x, -half_extents.y, half_extents.z),
        center + Float3::new(half_extents.x, half_extents.y, half_extents.z),
        center + Float3::new(-half_extents.x, half_extents.y, half_extents.z),
    ];
    for (a, b) in [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
    ] {
        append(corners[a], corners[b]);
    }
}

#[cfg(test)]
fn axis_component(vector: Float3, axis: usize) -> f32 {
    match axis {
        0 => vector.x,
        1 => vector.y,
        _ => vector.z,
    }
}

fn add_axis_component(vector: &mut Float3, axis: usize, delta: f32) {
    match axis {
        0 => vector.x += delta,
        1 => vector.y += delta,
        _ => vector.z += delta,
    }
}

fn append_ring_lines(
    center: Float3,
    radius: f32,
    axes: (usize, usize),
    append: &mut dyn FnMut(Float3, Float3),
) {
    let segment_count = 24;
    let mut previous = center;
    add_axis_component(&mut previous, axes.0, radius);
    for segment in 1..=segment_count {
        let angle = segment as f32 * 2.0 * PI / segment_count as f32;
        let mut next = center;
        add_axis_component(&mut next, axes.0, angle.cos() * radius);
        add_axis_component(&mut next, axes.1, angle.sin() * radius);
        append(previous, next);
        previous = next;
    }
}

fn append_capsule_arc_lines(
    center: Float3,
    radius: f32,
    half_height: f32,
    plane_axis: usize,
    append: &mut dyn FnMut(Float3, Float3),
) {
    let segment_count = 12;
    for sign in [-1.0f32, 1.0f32] {
        let mut previous = center;
        previous.y += sign * half_height;
        add_axis_component(&mut previous, plane_axis, radius);
        for segment in 1..=segment_count {
            let angle = segment as f32 * PI / segment_count as f32;
            let mut next = center;
            next.y += sign * (half_height + angle.sin() * radius);
            add_axis_component(&mut next, plane_axis, angle.cos() * radius);
            append(previous, next);
            previous = next;
        }
    }
}

fn append_joint_line(
    lines: &mut Vec<EditorPhysicsDebugLine>,
    limit: usize,
    entity_id: u64,
    a: Float3,
    b: Float3,
    kind: EditorPhysicsDebugLineKind,
) {
    if lines.len() >= limit {
        return;
    }
    lines.push(EditorPhysicsDebugLine {
        entity_id,
        position_a: a,
        position_b: b,
        kind,
    });
}

#[allow(clippy::too_many_arguments)]
fn append_joint_angular_limit(
    lines: &mut Vec<EditorPhysicsDebugLine>,
    limit: usize,
    entity_id: u64,
    anchor: Float3,
    axis: Float3,
    tangent: Float3,
    minimum: f32,
    maximum: f32,
    radius: f32,
) {
    let mut previous = anchor + rotate_vector(tangent * radius, axis, minimum);
    let segment_count = 24;
    for segment in 1..=segment_count {
        if lines.len() >= limit {
            continue;
        }
        let t = segment as f32 / segment_count as f32;
        let angle = minimum + (maximum - minimum) * t;
        let next = anchor + rotate_vector(tangent * radius, axis, angle);
        append_joint_line(
            lines,
            limit,
            entity_id,
            previous,
            next,
            EditorPhysicsDebugLineKind::JointLimit,
        );
        previous = next;
    }
}

fn rotate_vector(vector: Float3, axis: Float3, angle: f32) -> Float3 {
    vector * angle.cos()
        + simd_cross(axis, vector) * angle.sin()
        + axis * simd_dot(axis, vector) * (1.0 - angle.cos())
}

fn append_aabb_lines(
    bounds: &SpatialAABB,
    entity_id: u64,
    kind: EditorPhysicsDebugLineKind,
    lines: &mut Vec<EditorPhysicsDebugLine>,
    limit: usize,
) {
    let corners = [
        Float3::new(bounds.min.x, bounds.min.y, bounds.min.z),
        Float3::new(bounds.max.x, bounds.min.y, bounds.min.z),
        Float3::new(bounds.max.x, bounds.max.y, bounds.min.z),
        Float3::new(bounds.min.x, bounds.max.y, bounds.min.z),
        Float3::new(bounds.min.x, bounds.min.y, bounds.max.z),
        Float3::new(bounds.max.x, bounds.min.y, bounds.max.z),
        Float3::new(bounds.max.x, bounds.max.y, bounds.max.z),
        Float3::new(bounds.min.x, bounds.max.y, bounds.max.z),
    ];
    for (a, b) in [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
    ] {
        if lines.len() >= limit {
            continue;
        }
        lines.push(EditorPhysicsDebugLine {
            entity_id,
            position_a: corners[a],
            position_b: corners[b],
            kind,
        });
    }
}

fn world_aabb(local_min: Float3, local_max: Float3, matrix: Float4x4) -> (Float3, Float3) {
    let mut world_low = Float3::splat(f32::MAX);
    let mut world_high = Float3::splat(-f32::MAX);
    for x in [local_min.x, local_max.x] {
        for y in [local_min.y, local_max.y] {
            for z in [local_min.z, local_max.z] {
                let p = matrix * Float4::new(x, y, z, 1.0);
                let v = Float3::new(p.x, p.y, p.z);
                world_low = simd_min(world_low, v);
                world_high = simd_max(world_high, v);
            }
        }
    }
    (world_low, world_high)
}

fn world_aabb_corners(local_min: Float3, local_max: Float3, matrix: Float4x4) -> Vec<Float3> {
    let mut points: Vec<Float3> = Vec::with_capacity(8);
    for x in [local_min.x, local_max.x] {
        for y in [local_min.y, local_max.y] {
            for z in [local_min.z, local_max.z] {
                let p = matrix * Float4::new(x, y, z, 1.0);
                points.push(Float3::new(p.x, p.y, p.z));
            }
        }
    }
    points
}

/// Swift's unused private `rayAABBIntersect`. Kept only for the unit test below
/// so the translation stays complete without a `dead_code` allowance.
#[cfg(test)]
fn ray_aabb_intersect(
    origin: Float3,
    direction: Float3,
    aabb_min: Float3,
    aabb_max: Float3,
) -> Option<f32> {
    let mut tmin: f32 = -f32::MAX;
    let mut tmax: f32 = f32::MAX;
    for axis in 0..3 {
        let o = axis_component(origin, axis);
        let d = axis_component(direction, axis);
        let lo = axis_component(aabb_min, axis);
        let hi = axis_component(aabb_max, axis);
        if d.abs() < 1e-6 {
            if o < lo || o > hi {
                return None;
            }
            continue;
        }
        let inverse = 1.0 / d;
        let mut t1 = (lo - o) * inverse;
        let mut t2 = (hi - o) * inverse;
        if t1 > t2 {
            std::mem::swap(&mut t1, &mut t2);
        }
        tmin = tmin.max(t1);
        tmax = tmax.min(t2);
        if tmin > tmax {
            return None;
        }
    }
    if tmin > 0.0 {
        Some(tmin)
    } else if tmax > 0.0 {
        Some(tmax)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ray_aabb_intersect_reports_the_entry_distance() {
        let bounds_min = Float3::new(-1.0, -1.0, -1.0);
        let bounds_max = Float3::new(1.0, 1.0, 1.0);
        assert_eq!(
            ray_aabb_intersect(
                Float3::new(0.0, 0.0, 5.0),
                Float3::new(0.0, 0.0, -1.0),
                bounds_min,
                bounds_max
            ),
            Some(4.0)
        );
        assert_eq!(
            ray_aabb_intersect(
                Float3::new(5.0, 0.0, 5.0),
                Float3::new(0.0, 0.0, -1.0),
                bounds_min,
                bounds_max
            ),
            None
        );
    }
}
