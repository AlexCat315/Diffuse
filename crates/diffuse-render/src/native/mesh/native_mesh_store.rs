//! GPU mesh residency. Catalog revisions replace resources as a transaction,
//! and Device retirement protects frames still using old handles.

use std::sync::Arc;

use std::collections::BTreeMap;

use cove_graphics::rhi::{
    Buffer, BufferDescriptor, BufferUsage, Device, RhiError, RhiResult, Sampler,
    SamplerAddressMode, SamplerDescriptor, Texture, TextureDescriptor, TextureFormat,
    TextureSubresource, TextureUsage,
};
use cove_logging::{Level, LogEvent};
use diffuse_assets::asset_pipeline::{BuiltinMesh, MeshAsset, MeshSubmesh, OBJLoader};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::import::image_asset_decoder::DecodedTextureAsset;
use diffuse_assets::import::mesh_texture_resolver::MeshTextureResolver;
use diffuse_math::simd::simd_compat::Float3;

use crate::registries::mesh_bounds_registry::MeshBoundsRegistry;
use crate::registries::mesh_picking_registry::MeshPickingRegistry;
use crate::registries::mesh_texture_registry::MeshTextureRegistry;
use crate::registries::mesh_wireframe_registry::MeshWireframeRegistry;
use crate::render_backend_resource_bundle::url_for_resource;
use crate::support::log;

pub struct NativeMeshStore {
    pub device: Arc<Device>,
    pub sampler: Sampler,
    pub fallbacks: Vec<Texture>,
    builtins: BTreeMap<i64, NativeMesh>,
    builtin_assets: BTreeMap<i64, MeshAsset>,
    imported: BTreeMap<i64, NativeMesh>,
    pub revision: Option<u64>,
    registry: &'static AssetRegistry,
}

impl NativeMeshStore {
    pub fn new(device: &Arc<Device>, registry: &'static AssetRegistry) -> RhiResult<Self> {
        let sampler = device.make_sampler(SamplerDescriptor {
            address_mode_u: SamplerAddressMode::ClampToEdge,
            address_mode_v: SamplerAddressMode::ClampToEdge,
            ..SamplerDescriptor::default()
        })?;
        let mut store = NativeMeshStore {
            device: device.clone(),
            sampler,
            fallbacks: Vec::new(),
            builtins: BTreeMap::new(),
            builtin_assets: BTreeMap::new(),
            imported: BTreeMap::new(),
            revision: None,
            registry,
        };
        let result = (|| {
            for pixel in [
                [255u8, 255, 255, 255],
                [128, 128, 255, 255],
                [255, 255, 0, 255],
            ] {
                store.fallbacks.push(Self::texture(
                    device,
                    &DecodedTextureAsset::new(pixel.to_vec(), 1, 1),
                )?);
            }
            let cube = BuiltinMesh::cube(Some(Float3::new(1.0, 1.0, 1.0)));
            store
                .builtins
                .insert(0, NativeMesh::make(device, &cube, None)?);
            let mut fixture = cube.clone();
            if let Some(url) = url_for_resource("FinalBaseMesh", "obj", "") {
                fixture = OBJLoader::load(&url.to_string_lossy())
                    .map_err(|error| RhiError::invalid_argument(error.to_string()))?;
                fixture.normalize_to_unit_bounds(2.0);
            }
            store
                .builtins
                .insert(1, NativeMesh::make(device, &fixture, None)?);
            store.builtin_assets.insert(0, cube.clone());
            store.builtin_assets.insert(1, fixture.clone());
            store.publish_metadata(&cube, 0);
            store.publish_metadata(&fixture, 1);
            Ok(())
        })();
        if let Err(error) = result {
            for mesh in store.builtins.values() {
                mesh.destroy(device);
            }
            for texture in &store.fallbacks {
                device.destroy_texture(*texture);
            }
            device.destroy_sampler(store.sampler);
            return Err(error);
        }
        Ok(store)
    }

    /// Swift's `deinit` releases everything the store owns.
    pub fn destroy(&self) {
        for mesh in self.builtins.values() {
            mesh.destroy(&self.device);
        }
        for mesh in self.imported.values() {
            mesh.destroy(&self.device);
        }
        for texture in &self.fallbacks {
            self.device.destroy_texture(*texture);
        }
        self.device.destroy_sampler(self.sampler);
    }

    pub fn mesh(&self, index: i64) -> Option<&NativeMesh> {
        self.imported
            .get(&index)
            .or_else(|| self.builtins.get(&index))
    }

    pub fn resident_count(&self) -> usize {
        self.builtins
            .keys()
            .chain(self.imported.keys())
            .collect::<std::collections::HashSet<_>>()
            .len()
    }

    pub fn synchronize(&mut self) -> RhiResult<()> {
        let Some(catalog) = self.registry.mesh_catalog(self.revision) else {
            return Ok(());
        };
        let mut replacements: BTreeMap<i64, NativeMesh> = BTreeMap::new();
        let result = (|| {
            for entry in &catalog.meshes {
                replacements.insert(
                    entry.mesh_index,
                    NativeMesh::make(&self.device, &entry.mesh, entry.source_directory.as_deref())?,
                );
            }
            Ok(())
        })();
        if let Err(error) = result {
            for mesh in replacements.values() {
                mesh.destroy(&self.device);
            }
            return Err(error);
        }
        let removed: Vec<i64> = self
            .imported
            .keys()
            .copied()
            .filter(|index| !replacements.contains_key(index))
            .collect();
        for mesh in self.imported.values() {
            mesh.destroy(&self.device);
        }
        self.imported = replacements;
        self.revision = Some(catalog.revision);
        for index in removed {
            MeshBoundsRegistry::remove(index);
            MeshPickingRegistry::remove(index);
            MeshWireframeRegistry::remove(index);
            if let Some(asset) = self.builtin_assets.get(&index) {
                self.publish_metadata(asset, index);
            }
        }
        for entry in &catalog.meshes {
            self.publish_metadata(&entry.mesh, entry.mesh_index);
            if let Some(polygon) = &entry.polygon_mesh {
                MeshWireframeRegistry::register_polygon_mesh(entry.mesh_index, polygon);
            }
        }
        Ok(())
    }

    fn publish_metadata(&self, mesh: &MeshAsset, index: i64) {
        let (min, max) = mesh.local_bounds();
        MeshBoundsRegistry::register_min_max(index, min, max);
        MeshPickingRegistry::register(index, mesh);
        MeshWireframeRegistry::register_mesh(index, mesh);
        // Keep the decoded-texture cache warm beside the material metadata, as
        // the Swift version's MeshTextureRegistry consumers expect.
        MeshTextureRegistry::register(index, mesh, None);
    }

    pub fn texture(device: &Arc<Device>, image: &DecodedTextureAsset) -> RhiResult<Texture> {
        let texture = device.make_texture(TextureDescriptor::new(
            image.width,
            image.height,
            TextureFormat::Rgba8Unorm,
            TextureUsage::SAMPLED | TextureUsage::TRANSFER_DESTINATION,
        ))?;
        if device
            .upload_texture_data(
                texture,
                &image.pixels,
                cove_graphics::rhi::TextureUploadRegion::new(
                    image.width as i64,
                    image.height as i64,
                ),
                image.width * 4,
                TextureSubresource::new(0, 0),
            )
            .is_err()
        {
            device.destroy_texture(texture);
            return Err(cove_graphics::rhi::RhiError::OutOfMemory);
        }
        Ok(texture)
    }
}

#[derive(Clone)]
pub struct NativeMeshGeometry {
    pub vertices: Buffer,
    pub indices: Buffer,
    pub vertex_capacity: usize,
    pub index_capacity: usize,
    pub submeshes: Vec<MeshSubmesh>,
    pub bounds: (Float3, Float3),
}

impl NativeMeshGeometry {
    pub fn destroy(&self, device: &Arc<Device>) {
        device.destroy_buffer(self.vertices);
        device.destroy_buffer(self.indices);
    }
}

#[derive(Clone)]
pub struct NativeMesh {
    pub geometry: NativeMeshGeometry,
    pub materials: Vec<diffuse_assets::asset_pipeline::MeshMaterial>,
    pub textures: BTreeMap<usize, Texture>,
}

impl NativeMesh {
    pub fn make(
        device: &Arc<Device>,
        asset: &MeshAsset,
        source_directory: Option<&str>,
    ) -> RhiResult<Self> {
        let empty =
            asset.vertices.is_empty() && asset.indices.is_empty() && asset.submeshes.is_empty();
        if !(empty || (asset.vertex_count() > 0 && !asset.indices.is_empty()))
            || !asset
                .vertices
                .len()
                .is_multiple_of(MeshAsset::VERTEX_FLOAT_COUNT)
            || !asset.indices.len().is_multiple_of(3)
            || !asset.vertices.iter().all(|value| value.is_finite())
            || !asset
                .indices
                .iter()
                .all(|index| (*index as usize) < asset.vertex_count())
        {
            return Err(RhiError::invalid_argument(format!(
                "invalid mesh geometry: {}",
                asset.name.as_str()
            )));
        }
        if !asset.materials.iter().all(|material| {
            (0..4).all(|lane| float4_lane(material.base_color_factor, lane).is_finite())
                && material.alpha_cutoff.is_finite()
        }) {
            return Err(RhiError::invalid_argument(format!(
                "non-finite imported material: {}",
                asset.name.as_str()
            )));
        }
        let parts = if !empty && asset.submeshes.is_empty() {
            vec![MeshSubmesh::new(0, asset.index_count(), 0)]
        } else {
            asset.submeshes.clone()
        };
        if !parts.iter().all(|part| {
            part.index_start as usize <= asset.indices.len()
                && part.index_count as usize <= asset.indices.len() - part.index_start as usize
                && part.index_count % 3 == 0
                && part.material_index >= 0
                && asset.materials.len() > part.material_index as usize
        }) {
            return Err(RhiError::invalid_argument(format!(
                "invalid submesh range/material: {}",
                asset.name.as_str()
            )));
        }
        let vertex_size = 16usize.max(asset.vertex_buffer_size());
        let index_size = 16usize.max(asset.index_buffer_size());
        let vertices = device.make_buffer(BufferDescriptor::labelled(
            vertex_size,
            BufferUsage::VERTEX | BufferUsage::TRANSFER_DESTINATION,
            "native-mesh-vertices",
        ))?;
        let mut indices: Option<Buffer> = None;
        let mut textures: BTreeMap<usize, Texture> = BTreeMap::new();
        let result = (|| {
            let index_buffer = device.make_buffer(BufferDescriptor::labelled(
                index_size,
                BufferUsage::INDEX | BufferUsage::TRANSFER_DESTINATION,
                "native-mesh-indices",
            ))?;
            indices = Some(index_buffer);
            if !empty {
                // SAFETY: `asset.vertices` is a live `Vec<f32>`; the byte range
                // covers exactly its initialized storage.
                let vertex_bytes = unsafe {
                    std::slice::from_raw_parts(
                        asset.vertices.as_ptr().cast::<u8>(),
                        asset.vertices.len() * 4,
                    )
                };
                device.upload_buffer_data(vertices, 0, vertex_bytes)?;
                // SAFETY: same reasoning for the index buffer's `Vec<u32>`.
                let index_bytes = unsafe {
                    std::slice::from_raw_parts(
                        asset.indices.as_ptr().cast::<u8>(),
                        asset.indices.len() * 4,
                    )
                };
                device.upload_buffer_data(index_buffer, 0, index_bytes)?;
            }
            for (index, texture) in asset.textures.iter().enumerate() {
                let decoded = match MeshTextureResolver::decode(texture, source_directory) {
                    Ok(resolved) => resolved.texture,
                    Err(error) => {
                        log::renderer().log(&LogEvent::new(
                            Level::Warning,
                            format!(
                                "native mesh texture {}[{index}] uses fallback: {error}",
                                asset.name.as_str()
                            ),
                        ));
                        continue;
                    }
                };
                textures.insert(index, NativeMeshStore::texture(device, &decoded)?);
            }
            Ok(NativeMesh {
                geometry: NativeMeshGeometry {
                    vertices,
                    indices: index_buffer,
                    vertex_capacity: vertex_size,
                    index_capacity: index_size,
                    submeshes: parts,
                    bounds: asset.local_bounds(),
                },
                materials: asset.materials.clone(),
                textures: std::mem::take(&mut textures),
            })
        })();
        match result {
            Ok(mesh) => Ok(mesh),
            Err(error) => {
                device.destroy_buffer(vertices);
                if let Some(indices) = indices {
                    device.destroy_buffer(indices);
                }
                for texture in textures.values() {
                    device.destroy_texture(*texture);
                }
                Err(error)
            }
        }
    }

    pub fn destroy(&self, device: &Arc<Device>) {
        self.geometry.destroy(device);
        for texture in self.textures.values() {
            device.destroy_texture(*texture);
        }
    }
}

fn float4_lane(vector: diffuse_math::simd::simd_compat::Float4, lane: usize) -> f32 {
    match lane {
        0 => vector.x,
        1 => vector.y,
        2 => vector.z,
        _ => vector.w,
    }
}
