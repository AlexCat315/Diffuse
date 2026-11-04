//! Resident mesh shader modules sharing one explicit binding ABI. Module
//! creation is transactional, and ownership is independent of material
//! pipeline variants.

use std::sync::Arc;

use std::collections::BTreeMap;

use cove_graphics::rhi::{BindingLayout, Device, RhiError, RhiResult, ShaderModule, ShaderStage};

use crate::native::targets::native_shader_library::NativeShaderLibrary;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum NativeMeshShaderRole {
    Vertex,
    Color,
    Depth,
    Stylized,
    OutlineVertex,
    OutlineFragment,
}

impl NativeMeshShaderRole {
    /// Swift's `CaseIterable` order.
    pub const ALL: [NativeMeshShaderRole; 6] = [
        NativeMeshShaderRole::Vertex,
        NativeMeshShaderRole::Color,
        NativeMeshShaderRole::Depth,
        NativeMeshShaderRole::Stylized,
        NativeMeshShaderRole::OutlineVertex,
        NativeMeshShaderRole::OutlineFragment,
    ];

    pub fn program(self) -> &'static str {
        match self {
            NativeMeshShaderRole::Vertex | NativeMeshShaderRole::Color => "opaque_mesh",
            NativeMeshShaderRole::Depth => "opaque_depth",
            NativeMeshShaderRole::Stylized => "stylized_character",
            NativeMeshShaderRole::OutlineVertex | NativeMeshShaderRole::OutlineFragment => {
                "outline"
            }
        }
    }

    pub fn stage(self) -> ShaderStage {
        if self == NativeMeshShaderRole::Vertex || self == NativeMeshShaderRole::OutlineVertex {
            ShaderStage::Vertex
        } else {
            ShaderStage::Fragment
        }
    }
}

pub struct NativeMeshShaders {
    device: Arc<Device>,
    modules: BTreeMap<NativeMeshShaderRole, ShaderModule>,
    pub bindings: BindingLayout,
}

impl NativeMeshShaders {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let roles = NativeMeshShaderRole::ALL;
        let mut artifacts = Vec::with_capacity(roles.len());
        for role in roles {
            artifacts.push(NativeShaderLibrary::artifact(
                role.program(),
                device.backend_api(),
                role.stage(),
            )?);
        }
        let expected: &[(&str, u32)] = &[
            ("draw", 0),
            ("instances", 1),
            ("meshSampler", 2),
            ("baseTexture", 3),
            ("sceneLights", 4),
            ("normalTexture", 5),
            ("mrTexture", 6),
            ("shadow", 7),
            ("shadowSampler", 8),
            ("shadowTexture", 9),
            ("iblTexture", 10),
            ("skinParameters", 11),
            ("jointPalette", 12),
            ("style", 13),
        ];
        for artifact in &artifacts {
            if artifact.interface.bindings.len() != expected.len()
                || !artifact.interface.bindings.iter().all(|binding| {
                    expected
                        .iter()
                        .any(|(name, slot)| *name == binding.name && *slot == binding.slot)
                })
            {
                return Err(RhiError::layout_mismatch(
                    "native mesh shader binding ABI mismatch",
                ));
            }
        }
        let mut layout_descriptor = cove_graphics::rhi::reflected_binding_layout(&artifacts)?;
        // Ring-backed per-frame/per-batch blocks are bound with a dynamic
        // offset (draw/instances + scene lights/shadows + style) so the
        // binding set descriptor is stable across frames.
        let dynamic_slots = [0u32, 1, 4, 7, 13];
        for entry in &mut layout_descriptor.entries {
            if dynamic_slots.contains(&entry.slot) {
                entry.buffer.has_dynamic_offset = true;
            }
        }
        let bindings = device.make_binding_layout(layout_descriptor)?;
        let mut created: BTreeMap<NativeMeshShaderRole, ShaderModule> = BTreeMap::new();
        let result = (|| {
            for (role, artifact) in roles.iter().zip(artifacts.iter()) {
                created.insert(
                    *role,
                    device.make_shader_module(artifact.module_descriptor(&[])?)?,
                );
            }
            Ok(())
        })();
        if let Err(error) = result {
            for module in created.values() {
                device.destroy_shader_module(*module);
            }
            return Err(error);
        }
        Ok(NativeMeshShaders {
            device: device.clone(),
            modules: created,
            bindings,
        })
    }

    /// Swift's `deinit` destroys every module.
    pub fn destroy(&self) {
        for module in self.modules.values() {
            self.device.destroy_shader_module(*module);
        }
    }

    pub fn module(&self, role: NativeMeshShaderRole) -> ShaderModule {
        self.modules[&role]
    }
}
