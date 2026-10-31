//! Derived query-only surfaces for soft bodies.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselSoftSurfaces.swift`.
//!
//! Characters must be able to stand on a deformable mesh, but the solver's soft bodies
//! are not queryable shapes. This module bakes each soft body into a separate static
//! mesh body whose filter lives in **bits 16...31** of the layer mask. Characters query
//! that shifted copy, so they collide with deformables without the derived surfaces
//! ever entering the physical solver.

use natsel::types::shape_def::{Filter, ShapeDef};

use crate::entity_id::EntityID;

use super::natsel_physics_backend::{NatselPhysicsBackend, ShapeIdKey, ShapeOwner};

/// Physical categories use bits 0...15; the query copy of those layers sits in 16...31.
pub(crate) const SOFT_QUERY_LAYER_SHIFT: u32 = 16;

impl NatselPhysicsBackend {
    /// `ensureSoftQuerySurfaces()` — rebuild the derived bodies when the dirty flag is
    /// set. Rebuilding is all-or-nothing: every surface is destroyed first, so a soft
    /// body that vanished cannot leave a stale queryable mesh behind.
    pub(crate) fn ensure_soft_query_surfaces(&mut self) {
        if !self.soft_query_surfaces_dirty {
            return;
        }
        // Drop the previous generation, including its owner entries.
        let stale: Vec<(EntityID, super::natsel_physics_backend::SoftQuerySurface)> = self
            .soft_query_surfaces
            .iter()
            .map(|(entity, surface)| (*entity, *surface))
            .collect();
        for (_, surface) in stale {
            self.owners.remove(&ShapeIdKey::of(surface.shape));
            self.world.destroy_body(surface.body);
        }
        self.soft_query_surfaces.clear();

        let mut entities: Vec<EntityID> = self.soft_bodies.keys().copied().collect();
        entities.sort_by_key(|entity| entity.raw_value());
        for entity in entities {
            let Some(record) = self.soft_bodies.get(&entity) else {
                continue;
            };
            let record_id = record.id;
            let indices: Vec<i32> = record
                .descriptor
                .topology
                .triangle_indices()
                .iter()
                .map(|index| *index as i32)
                .collect();
            let config = record.descriptor.soft_body.clone();
            let vertices = self.world.soft_body_vertex_positions(record_id);
            if vertices.is_empty() {
                continue;
            }
            let origin = vertices[0];
            let local: Vec<natsel::math::types::Vec3> = vertices
                .iter()
                .map(|vertex| {
                    natsel::math::types::Vec3::new(
                        (vertex.x - origin.x) as f32,
                        (vertex.y - origin.y) as f32,
                        (vertex.z - origin.z) as f32,
                    )
                })
                .collect();
            let Some(mesh) = natsel::collision::mesh::storage::TriangleMesh::new(
                &local,
                &indices,
                None,
                natsel::collision::mesh::build::MeshBuildOptions::default(),
            ) else {
                continue;
            };
            let body_def = natsel::types::body_def::BodyDef {
                position: origin,
                ..natsel::types::body_def::BodyDef::default()
            };
            let body = self.world.create_body(&body_def);
            // The mask is shifted so these surfaces only answer the query copy.
            let shape_def = ShapeDef {
                filter: Filter::new(
                    1u64 << config.layer_id.min(15),
                    u64::from(config.layer_mask) << SOFT_QUERY_LAYER_SHIFT,
                    0,
                ),
                materials: vec![natsel::types::shape_def::SurfaceMaterial::default_material()],
                ..ShapeDef::default()
            };
            let shape = self.world.create_mesh_shape(
                body,
                &shape_def,
                mesh,
                natsel::math::types::Vec3::new(1.0, 1.0, 1.0),
            );
            if shape.is_null() {
                self.world.destroy_body(body);
                continue;
            }
            self.owners
                .insert(ShapeIdKey::of(shape), ShapeOwner { entity, child: 0 });
            self.soft_query_surfaces.insert(
                entity,
                super::natsel_physics_backend::SoftQuerySurface { body, shape },
            );
        }
        self.soft_query_surfaces_dirty = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_flag_skips_the_rebuild() {
        let mut backend = NatselPhysicsBackend::new();
        backend.soft_query_surfaces_dirty = false;
        let bodies_before = backend.world.body_count();
        backend.ensure_soft_query_surfaces();
        assert_eq!(backend.world.body_count(), bodies_before);
    }

    #[test]
    fn empty_soft_body_set_clears_and_resets_the_flag() {
        let mut backend = NatselPhysicsBackend::new();
        backend.soft_query_surfaces_dirty = true;
        backend.ensure_soft_query_surfaces();
        assert!(backend.soft_query_surfaces.is_empty());
        assert!(!backend.soft_query_surfaces_dirty);
    }

    #[test]
    fn shift_is_sixteen() {
        assert_eq!(SOFT_QUERY_LAYER_SHIFT, 16);
    }
}
