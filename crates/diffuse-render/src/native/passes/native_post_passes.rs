//! Fullscreen effects own resident pipelines/targets, while all uniforms and
//! bindings belong to the frame. History validity lives in RenderTemporalState.

use std::sync::Arc;

use std::collections::BTreeMap;

use cove_graphics::rhi::{
    BindingResource, BindingSetEntry, CommandBuffer, Device, RhiError, RhiResult, Sampler,
    SamplerAddressMode, SamplerDescriptor, SamplerFilter, SamplerMipFilter, Texture,
};

use crate::core::frame::render_frame_plan::{RenderFramePlanner, RenderPassKind};
use crate::core::frame::render_packet::RenderDrawableSize;
use crate::core::frame::render_uniforms::PostFrameUniforms;
use crate::core::lighting::post_effect_uniforms::PostEffectUniforms;
use crate::core::render_settings::RenderSettings;
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::passes::native_fullscreen_pass::NativeFullscreenPass;
use crate::native::passes::native_post_targets::{NativePostRequirements, NativePostTargets};

pub struct NativePostPasses {
    device: Arc<Device>,
    sampler: Sampler,
    pipelines: BTreeMap<RenderPassKind, NativeFullscreenPass>,
    targets: Option<NativePostTargets>,
    pub revision: u64,
}

impl NativePostPasses {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let sampler = device.make_sampler(SamplerDescriptor {
            min_filter: SamplerFilter::Linear,
            mag_filter: SamplerFilter::Linear,
            mip_filter: SamplerMipFilter::Nearest,
            address_mode_u: SamplerAddressMode::ClampToEdge,
            address_mode_v: SamplerAddressMode::ClampToEdge,
            ..SamplerDescriptor::default()
        })?;
        Ok(NativePostPasses {
            device: device.clone(),
            sampler,
            pipelines: BTreeMap::new(),
            targets: None,
            revision: 0,
        })
    }

    /// Swift's `deinit` destroys the targets and the sampler.
    pub fn destroy(&self) {
        for pipeline in self.pipelines.values() {
            pipeline.destroy();
        }
        if let Some(targets) = &self.targets {
            targets.destroy(&self.device);
        }
        self.device.destroy_sampler(self.sampler);
    }

    pub fn targets(&self) -> Option<&NativePostTargets> {
        self.targets.as_ref()
    }

    pub fn ensure_targets(
        &mut self,
        size: RenderDrawableSize,
        requirements: NativePostRequirements,
    ) -> RhiResult<()> {
        if let Some(targets) = &self.targets
            && targets.size == size
            && targets.requirements == requirements
        {
            return Ok(());
        }
        let replacement = NativePostTargets::make(&self.device, size, requirements)?;
        if let Some(previous) = self.targets.take() {
            previous.destroy(&self.device);
        }
        self.targets = Some(replacement);
        self.revision = self.revision.wrapping_add(1);
        Ok(())
    }

    /// Allocates and returns the opaque-cache snapshot on first stable capture.
    pub fn ensure_snapshot(&mut self) -> RhiResult<Texture> {
        let Some(targets) = self.targets.as_mut() else {
            return Err(RhiError::OutOfMemory);
        };
        targets.ensure_snapshot(&self.device)
    }

    pub fn snapshot(&self) -> Option<Texture> {
        self.targets.as_ref().and_then(|targets| targets.snapshot)
    }

    pub fn prewarm(&mut self, settings: &RenderSettings) -> RhiResult<()> {
        let fullscreen = [
            RenderPassKind::Ssao,
            RenderPassKind::Ssr,
            RenderPassKind::Taa,
            RenderPassKind::Bloom,
            RenderPassKind::Fxaa,
            RenderPassKind::InkPaperPost,
        ];
        for kind in RenderFramePlanner::make_plan(settings).passes {
            if fullscreen.contains(&kind) {
                self.pipeline_for(kind)?;
            }
        }
        Ok(())
    }

    fn pipeline_for(&mut self, kind: RenderPassKind) -> RhiResult<&NativeFullscreenPass> {
        if self.pipelines.contains_key(&kind) {
            return Ok(self.pipelines.get(&kind).expect("existing pipeline"));
        }
        let result = NativeFullscreenPass::new(
            &self.device,
            if kind == RenderPassKind::InkPaperPost {
                "ink_paper_post"
            } else {
                kind.raw_value()
            },
            if kind == RenderPassKind::Fxaa {
                cove_graphics::rhi::TextureFormat::Bgra8Unorm
            } else {
                cove_graphics::rhi::TextureFormat::Rgba16Float
            },
            None,
        )?;
        self.pipelines.insert(kind, result);
        Ok(self
            .pipelines
            .get(&kind)
            .expect("pipeline was just inserted"))
    }

    #[allow(
        clippy::too_many_arguments,
        reason = "Keep the original render API argument grouping."
    )]
    pub fn encode<T: Copy>(
        &mut self,
        kind: RenderPassKind,
        input: Texture,
        secondary: Texture,
        output: Texture,
        uniforms: T,
        size: RenderDrawableSize,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        self.pipeline_for(kind)?;
        let pipeline = self
            .pipelines
            .get(&kind)
            .expect("pipeline was just prepared");
        let Some(targets) = self.targets.as_ref() else {
            return Err(RhiError::OutOfMemory);
        };
        let frame = PostEffectUniforms::frame(size, targets.size);
        pipeline.encode(
            size,
            cove_graphics::rhi::RenderColorTarget::clearing(output, [0.0; 4]),
            None,
            vec![
                BindingSetEntry::new(0, BindingResource::Sampler(self.sampler)),
                BindingSetEntry::new(1, BindingResource::Texture(input)),
                BindingSetEntry::new(2, BindingResource::Texture(secondary)),
                BindingSetEntry::new(3, NativeUniformUpload::binding(uniforms, &self.device)?),
                BindingSetEntry::new(
                    4,
                    NativeUniformUpload::binding(
                        PostFrameUniforms {
                            uv_scale_max: frame.uv_scale_max,
                        },
                        &self.device,
                    )?,
                ),
            ],
            commands,
        )
    }
}
