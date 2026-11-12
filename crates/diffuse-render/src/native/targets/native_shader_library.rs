//! Loads offline artifacts and combines target-specific reflected bindings.

use serde::Deserialize;
use std::path::Path;

use cove_graphics::rhi::{GraphicsApi, RhiError, RhiResult, ShaderArtifact, ShaderStage};

use crate::render_backend_resource_bundle::RenderBackendResourceBundle;

#[derive(Deserialize)]
struct ComputeFamily {
    base: serde_json::Value,
    variants: std::collections::BTreeMap<String, serde_json::Value>,
}

pub enum NativeShaderLibrary {}

impl NativeShaderLibrary {
    pub fn compute_artifact(
        name: &str,
        api: GraphicsApi,
        workgroup_size: Option<usize>,
    ) -> RhiResult<ShaderArtifact> {
        let artifact = Self::artifact(name, api, ShaderStage::Compute)?;
        let Some(workgroup_size) = workgroup_size else {
            return Ok(artifact);
        };
        if !(1..=256).contains(&workgroup_size) {
            return Err(RhiError::invalid_argument(
                "particle workgroup must be in 1...256",
            ));
        }
        if artifact.interface.threadgroup_specialization.x.is_some() {
            return Ok(artifact);
        }
        if artifact.interface.threadgroup_size.x == workgroup_size as i64 {
            return Ok(artifact);
        }
        let Some(bytes) = crate::render_backend_resource_bundle::url_for_resource(
            &format!("{name}.compute.workgroups"),
            "json",
            &format!("Shaders/Native/{}", Self::target(api)),
        )
        .and_then(|url| std::fs::read(url).ok()) else {
            return Err(RhiError::unsupported_feature(format!(
                "missing offline workgroup family for {name}"
            )));
        };
        let family: ComputeFamily = serde_json::from_slice(&bytes).map_err(|error| {
            RhiError::layout_mismatch(format!("invalid workgroup family: {error}"))
        })?;
        let Some(variant) = family.variants.get(&workgroup_size.to_string()) else {
            return Err(RhiError::layout_mismatch(format!(
                "missing {name} workgroup variant {workgroup_size}"
            )));
        };
        let mut base = family.base;
        base.as_object_mut()
            .ok_or_else(|| RhiError::layout_mismatch("invalid workgroup base artifact"))?
            .insert("code".into(), variant.clone());
        let bytes = serde_json::to_vec(&base)
            .map_err(|error| RhiError::layout_mismatch(error.to_string()))?;
        let mut result = ShaderArtifact::from_json(&bytes)?;
        result.interface.threadgroup_size.x = workgroup_size as i64;
        Ok(result)
    }

    pub fn artifact(name: &str, api: GraphicsApi, stage: ShaderStage) -> RhiResult<ShaderArtifact> {
        ShaderArtifact::load_directory(
            RenderBackendResourceBundle::bundle().root(),
            name,
            stage,
            api,
            Path::new("Shaders/Native"),
            Some(Self::target(api)),
        )
    }

    fn target(api: GraphicsApi) -> &'static str {
        match api {
            GraphicsApi::Metal => "metal",
            GraphicsApi::Dx12 => "dxil",
            GraphicsApi::WebGpu => "wgsl",
            GraphicsApi::Vulkan => {
                // Swift's `#if os(Android)` branch.
                if cfg!(target_os = "android") {
                    "spirv-mobile"
                } else {
                    "spirv"
                }
            }
        }
    }
}
