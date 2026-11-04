//! An immutable compute program. Bindings are owned by the recording frame.

use std::sync::Arc;

use std::collections::BTreeMap;

use cove_graphics::rhi::{
    BindingLayout, BindingSetDescriptor, BindingSetEntry, CommandBuffer, ComputePipeline,
    ComputePipelineDescriptor, Device, PipelineLayoutDescriptor, RhiError, RhiResult,
    ShaderConstantValue, ShaderSpecializationConstant,
};

use crate::native::targets::native_shader_library::NativeShaderLibrary;

pub struct NativeComputePass {
    device: Arc<Device>,
    bindings: BindingLayout,
    pipeline: ComputePipeline,
}

impl NativeComputePass {
    pub fn new(device: &Arc<Device>, shader: &str) -> RhiResult<Self> {
        Self::with_options(device, shader, &BTreeMap::new(), None)
    }

    pub fn with_options(
        device: &Arc<Device>,
        shader: &str,
        buffer_strides: &BTreeMap<u32, i64>,
        workgroup_size: Option<usize>,
    ) -> RhiResult<Self> {
        let artifact =
            NativeShaderLibrary::compute_artifact(shader, device.backend_api(), workgroup_size)?;
        for (slot, stride) in buffer_strides {
            let Some(binding) = artifact
                .interface
                .bindings
                .iter()
                .find(|binding| binding.slot == *slot)
            else {
                return Err(RhiError::layout_mismatch(format!(
                    "{shader} buffer {slot} shader/host stride differs"
                )));
            };
            if binding.buffer.element_stride != *stride {
                return Err(RhiError::layout_mismatch(format!(
                    "{shader} buffer {slot} shader/host stride differs"
                )));
            }
        }
        let bindings = device.make_binding_layout(artifact.binding_layout_descriptor(0)?)?;
        let layout = device.make_pipeline_layout(PipelineLayoutDescriptor::new(vec![bindings]))?;
        let mut constants: Vec<ShaderSpecializationConstant> = Vec::new();
        if let (Some(workgroup_size), Some(id)) = (
            workgroup_size,
            artifact.interface.threadgroup_specialization.x,
        ) {
            constants = vec![ShaderSpecializationConstant::new(
                id,
                ShaderConstantValue::Uint32(workgroup_size as u32),
            )];
        }
        let module = device.make_shader_module(artifact.module_descriptor(&constants)?)?;
        let pipeline =
            device.make_compute_pipeline(ComputePipelineDescriptor::new(layout, module))?;
        device.destroy_shader_module(module);
        Ok(NativeComputePass {
            device: device.clone(),
            bindings,
            pipeline,
        })
    }

    /// Swift's `deinit` destroys the pipeline.
    pub fn destroy(&self) {
        self.device.destroy_compute_pipeline(self.pipeline);
    }

    pub fn encode(
        &self,
        entries: Vec<BindingSetEntry>,
        groups: i64,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        let set = self
            .device
            .make_binding_set(self.bindings, BindingSetDescriptor::new(entries))?;
        commands.compute_pass(|encoder| {
            encoder.set_pipeline(self.pipeline);
            encoder.set_binding_set(set, 0, Vec::new());
            encoder.dispatch(groups, 1, 1);
        });
        Ok(())
    }
}
