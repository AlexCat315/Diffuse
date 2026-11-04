//! Deformable mesh upload: grow-only GPU buffers per entity with transactional
//! commit semantics. Owns new allocations until command submission succeeds;
//! recording a copy alone must not advance resident revisions or retire the
//! previous geometry.

use std::sync::Arc;

use std::collections::{BTreeMap, BTreeSet};

use cove_graphics::rhi::{Buffer, BufferDescriptor, BufferUsage, CommandBuffer, Device, RhiResult};
use diffuse_assets::asset_pipeline::{MeshAsset, MeshSubmesh};
use diffuse_math::simd::simd_compat::{Float3, Float4, simd_cross, simd_normalize};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_scene::RenderDeformableMesh;

use crate::core::mesh::deformable_upload_report::DeformableMeshUploadReport;
use crate::native::mesh::native_mesh_store::NativeMeshGeometry;

/// CPU-side interleaved stream matching the static `MeshAsset` vertex layout
/// (the core file owns the shared conversion; this copy feeds the upload paths
/// in the Swift file's host, DeformableMeshVertexStream).
pub struct NativeDeformableStream {
    pub vertices: Vec<f32>,
    pub indices: Vec<u32>,
}

impl NativeDeformableStream {
    /// Swift's `DeformableMeshVertexStream.init?` — `None` for invalid meshes.
    pub fn new(mesh: &RenderDeformableMesh) -> Option<Self> {
        if !mesh.is_valid() {
            return None;
        }
        let mut vertices: Vec<f32> =
            Vec::with_capacity(mesh.vertex_count() * MeshAsset::VERTEX_FLOAT_COUNT);
        for index in 0..mesh.positions.len() {
            let input = mesh.normals[index];
            let normal = if simd_length_squared(input) > 0.000_001 {
                input
            } else {
                Float3::new(0.0, 1.0, 0.0)
            };
            MeshAsset::append_vertex(
                &mut vertices,
                mesh.positions[index],
                normal,
                Float3::ZERO,
                mesh.texture_coordinates[index],
                Self::tangent(normal),
                0.0,
                Float4::ZERO,
                Float4::ZERO,
            );
        }
        Some(NativeDeformableStream {
            vertices,
            indices: mesh.triangle_indices.clone(),
        })
    }

    pub fn vertex_buffer_size(&self) -> usize {
        self.vertices.len() * 4
    }

    pub fn index_buffer_size(&self) -> usize {
        self.indices.len() * 4
    }

    fn tangent(normal: Float3) -> Float4 {
        let reference = if normal.y.abs() < 0.95 {
            Float3::new(0.0, 1.0, 0.0)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let tangent = simd_normalize(simd_cross(reference, normal));
        Float4::new(tangent.x, tangent.y, tangent.z, 1.0)
    }
}

fn simd_length_squared(value: Float3) -> f32 {
    value.x * value.x + value.y * value.y + value.z * value.z
}

#[derive(Clone)]
pub struct NativeDeformableResource {
    pub geometry: NativeMeshGeometry,
    pub revision: u64,
    pub topology_revision: u64,
    pub vertex_count: usize,
    pub triangle_count: usize,
}

/// Owns new allocations until command submission succeeds.
pub struct NativeDeformableUpdate {
    pub device: Arc<Device>,
    pub resources: BTreeMap<EntityID, NativeDeformableResource>,
    pub allocated: BTreeSet<Buffer>,
    pub report: DeformableMeshUploadReport,
    committed: bool,
}

impl NativeDeformableUpdate {
    fn new(device: &Arc<Device>) -> Self {
        NativeDeformableUpdate {
            device: device.clone(),
            resources: BTreeMap::new(),
            allocated: BTreeSet::new(),
            report: DeformableMeshUploadReport::default(),
            committed: false,
        }
    }

    /// Swift's `deinit` destroys uncommitted allocations.
    pub fn destroy(&self) {
        if !self.committed {
            for buffer in &self.allocated {
                self.device.destroy_buffer(*buffer);
            }
        }
    }

    pub fn buffers(&self) -> BTreeSet<Buffer> {
        self.resources
            .values()
            .flat_map(|resource| [resource.geometry.vertices, resource.geometry.indices])
            .collect()
    }

    pub fn geometries(&self) -> BTreeMap<EntityID, NativeMeshGeometry> {
        self.resources
            .iter()
            .map(|(entity, resource)| (*entity, resource.geometry.clone()))
            .collect()
    }

    pub fn commit(&mut self, retiring: BTreeSet<Buffer>) {
        let retained = self.buffers();
        for buffer in retiring.difference(&retained) {
            self.device.destroy_buffer(*buffer);
        }
        self.committed = true;
    }
}

pub struct NativeDeformableMeshes {
    device: Arc<Device>,
    resources: BTreeMap<EntityID, NativeDeformableResource>,
}

impl NativeDeformableMeshes {
    pub fn new(device: &Arc<Device>) -> Self {
        NativeDeformableMeshes {
            device: device.clone(),
            resources: BTreeMap::new(),
        }
    }

    /// Swift's `deinit` destroys every resident geometry.
    pub fn destroy(&self) {
        for resource in self.resources.values() {
            resource.geometry.destroy(&self.device);
        }
    }

    pub fn prepare(
        &self,
        meshes: &[RenderDeformableMesh],
        commands: &mut CommandBuffer,
    ) -> RhiResult<NativeDeformableUpdate> {
        let mut update = NativeDeformableUpdate::new(&self.device);
        let mut sorted: Vec<&RenderDeformableMesh> = meshes.iter().collect();
        sorted.sort_by_key(|mesh| mesh.entity.raw_value());
        for mesh in sorted {
            if update.resources.contains_key(&mesh.entity) || !mesh.is_valid() {
                update.report.rejected_mesh_count += 1;
                continue;
            }
            update.report.mesh_count += 1;
            update.report.vertex_count += mesh.vertex_count();
            update.report.triangle_count += mesh.triangle_count();
            let previous = self.resources.get(&mesh.entity);
            let vertices_changed = previous.is_none_or(|previous| {
                previous.revision != mesh.revision || previous.vertex_count != mesh.vertex_count()
            });
            let topology_changed = previous.is_none_or(|previous| {
                previous.topology_revision != mesh.topology_revision
                    || previous.triangle_count != mesh.triangle_count()
            });
            if !vertices_changed
                && !topology_changed
                && let Some(previous) = previous
            {
                update.resources.insert(mesh.entity, previous.clone());
                continue;
            }
            let Some(stream) = NativeDeformableStream::new(mesh) else {
                continue;
            };
            let vertex_size = stream.vertex_buffer_size();
            let index_size = stream.index_buffer_size();
            let vertices = self.buffer(
                previous.map(|previous| previous.geometry.vertices),
                previous.map_or(0, |previous| previous.geometry.vertex_capacity),
                vertex_size,
                BufferUsage::VERTEX,
                &mut update,
            )?;
            let indices = self.buffer(
                previous.map(|previous| previous.geometry.indices),
                previous.map_or(0, |previous| previous.geometry.index_capacity),
                index_size,
                BufferUsage::INDEX,
                &mut update,
            )?;
            if vertices_changed
                || previous.is_none_or(|previous| previous.geometry.vertices != vertices)
            {
                Self::copy(&self.device, &stream.vertices, vertices, commands)?;
                update.report.uploaded_bytes += stream.vertex_buffer_size() as u64;
            }
            if topology_changed
                || previous.is_none_or(|previous| previous.geometry.indices != indices)
            {
                Self::copy(&self.device, &stream.indices, indices, commands)?;
                update.report.uploaded_bytes += stream.index_buffer_size() as u64;
            }
            let (bounds_min, bounds_max) = mesh.world_bounds();
            let geometry = NativeMeshGeometry {
                vertices,
                indices,
                vertex_capacity: vertex_size
                    .max(previous.map_or(0, |previous| previous.geometry.vertex_capacity)),
                index_capacity: index_size
                    .max(previous.map_or(0, |previous| previous.geometry.index_capacity)),
                submeshes: vec![MeshSubmesh::new(0, stream.indices.len() as u32, 0)],
                bounds: (bounds_min, bounds_max),
            };
            update.resources.insert(
                mesh.entity,
                NativeDeformableResource {
                    geometry,
                    revision: mesh.revision,
                    topology_revision: mesh.topology_revision,
                    vertex_count: mesh.vertex_count(),
                    triangle_count: mesh.triangle_count(),
                },
            );
        }
        Ok(update)
    }

    pub fn commit(&mut self, update: NativeDeformableUpdate) {
        let retiring: BTreeSet<Buffer> = self
            .resources
            .values()
            .flat_map(|resource| [resource.geometry.vertices, resource.geometry.indices])
            .collect();
        let mut update = update;
        update.commit(retiring);
        self.resources = update.resources;
    }

    fn buffer(
        &self,
        previous: Option<Buffer>,
        capacity: usize,
        size: usize,
        usage: BufferUsage,
        update: &mut NativeDeformableUpdate,
    ) -> RhiResult<Buffer> {
        if let Some(previous) = previous
            && capacity >= size
        {
            return Ok(previous);
        }
        let result = self.device.make_buffer(BufferDescriptor::new(
            size,
            usage | BufferUsage::TRANSFER_DESTINATION,
        ))?;
        update.allocated.insert(result);
        Ok(result)
    }

    fn copy<T: Copy>(
        device: &Arc<Device>,
        values: &[T],
        to: Buffer,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        if values.is_empty() {
            return Ok(());
        }
        // SAFETY: `values` is a live slice of `Copy` values; the byte range is
        // fully initialized.
        let data = unsafe {
            std::slice::from_raw_parts(values.as_ptr().cast::<u8>(), std::mem::size_of_val(values))
        };
        let upload = device.upload_transient(data, 256)?;
        commands.copy_pass(|copy| {
            copy.copy_buffer(upload.buffer, upload.offset, to, 0, data.len());
        });
        Ok(())
    }
}
