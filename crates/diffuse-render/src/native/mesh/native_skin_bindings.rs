//! Per-entity joint-palette bindings for the current frame.

use std::collections::BTreeMap;

use cove_graphics::rhi::{BindingResource, Device, RhiResult};
use diffuse_math::simd::simd_compat::{Float4x4, MATRIX_IDENTITY_FLOAT4X4, UInt4};
use diffuse_scene::entity_id::EntityID;

use crate::core::frame::render_packet::RenderPacket;
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;

#[derive(Clone)]
pub struct NativeSkinPalette {
    pub parameters: BindingResource,
    pub matrices: BindingResource,
}

/// A palette belongs to this frame, including its explicit logical length.
/// Removing or shrinking a palette cannot expose a previous frame's matrices.
#[derive(Clone)]
pub struct NativeSkinBindings {
    palettes: BTreeMap<EntityID, NativeSkinPalette>,
    fallback: NativeSkinPalette,
}

impl NativeSkinBindings {
    pub fn new(packet: &RenderPacket, device: &Device) -> RhiResult<Self> {
        let fallback = Self::upload(&[], device)?;
        let mut palettes = BTreeMap::new();
        // Swift sorts by entity raw value before uploading.
        for (entity, palette) in packet.joint_palette_map.palettes.iter() {
            let uploaded = if palette.matrices.is_empty() {
                fallback.clone()
            } else {
                Self::upload(&palette.matrices, device)?
            };
            palettes.insert(*entity, uploaded);
        }
        Ok(NativeSkinBindings { palettes, fallback })
    }

    pub fn palette(&self, entity: Option<EntityID>) -> &NativeSkinPalette {
        entity
            .and_then(|entity| self.palettes.get(&entity))
            .unwrap_or(&self.fallback)
    }

    fn upload(matrices: &[Float4x4], device: &Device) -> RhiResult<NativeSkinPalette> {
        // Swift packs `SIMD4<UInt32>(UInt32(max(matrices.count,1)),0,0,0)`.
        let parameters = NativeUniformUpload::binding(
            UInt4::new(matrices.len().max(1) as u32, 0, 0, 0),
            device,
        )?;
        let effective: Vec<Float4x4> = if matrices.is_empty() {
            vec![MATRIX_IDENTITY_FLOAT4X4]
        } else {
            matrices.to_vec()
        };
        // SAFETY: `effective` is a live `Vec<Float4x4>` of `#[repr(C)]` `Copy`
        // values, so the byte range is fully initialized.
        let data = unsafe {
            std::slice::from_raw_parts(
                effective.as_ptr().cast::<u8>(),
                effective.len() * std::mem::size_of::<Float4x4>(),
            )
        };
        let upload = device.upload_transient(data, 256)?;
        Ok(NativeSkinPalette {
            parameters,
            matrices: BindingResource::StorageBuffer {
                buffer: upload.buffer,
                offset: upload.offset,
            },
        })
    }
}
