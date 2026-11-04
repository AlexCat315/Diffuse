//! Loads offline artifacts and combines target-specific reflected bindings.

use serde::Deserialize;

use cove_graphics::rhi::{
    GraphicsApi, RhiError, RhiResult, ShaderArtifact, ShaderFormat, ShaderStage,
};

use crate::render_backend_resource_bundle::RenderBackendResourceBundle;

#[derive(Deserialize)]
struct ComputeFamily {
    base: ComputeFamilyArtifact,
    variants: std::collections::BTreeMap<String, serde_json::Value>,
}

/// The subset of `ShaderArtifact` the workgroup-family JSON carries; deserialized
/// through the RHI's own JSON reader so the shapes stay identical.
#[derive(Deserialize)]
struct ComputeFamilyArtifact {
    stage: ShaderStage,
    format: ShaderFormat,
    entry_point: String,
    code: serde_json::Value,
    interface: serde_json::Value,
    compiler: String,
    #[serde(default)]
    source_fingerprint: Option<String>,
}

impl ComputeFamilyArtifact {
    /// Reassembles the artifact with a variant's code. The interface JSON is
    /// reparsed through `ShaderArtifact::from_json` semantics by building the
    /// struct directly; the code is a base64 string in the offline files.
    fn into_artifact(self, code: &[u8]) -> RhiResult<ShaderArtifact> {
        let interface: cove_graphics::rhi::ShaderInterface = serde_json::from_value(self.interface)
            .map_err(|error| {
                RhiError::layout_mismatch(format!("invalid shader interface: {error}"))
            })?;
        Ok(ShaderArtifact {
            stage: self.stage,
            format: self.format,
            entry_point: self.entry_point,
            code: code.to_vec(),
            interface,
            compiler: self.compiler,
            source_fingerprint: self.source_fingerprint,
        })
    }
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
        let code = decode_variant_code(variant)?;
        let mut result = family.base.into_artifact(&code)?;
        result.interface.threadgroup_size.x = workgroup_size as i64;
        Ok(result)
    }

    pub fn artifact(name: &str, api: GraphicsApi, stage: ShaderStage) -> RhiResult<ShaderArtifact> {
        let path = format!(
            "Shaders/Native/{}/{}.{}.json",
            Self::target(api),
            name,
            stage_file_name(stage)
        );
        let bytes = RenderBackendResourceBundle::bundle()
            .read(Path::new(&path))
            .map_err(|error| {
                RhiError::unsupported_feature(format!("missing offline shader {path}: {error}"))
            })?;
        let artifact = ShaderArtifact::from_json(&bytes)?;
        if artifact.stage != stage {
            return Err(RhiError::layout_mismatch("shader artifact stage mismatch"));
        }
        Ok(artifact)
    }

    fn target(api: GraphicsApi) -> &'static str {
        match api {
            GraphicsApi::Metal => "metal",
            GraphicsApi::Dx12 => "dxil",
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

fn stage_file_name(stage: ShaderStage) -> &'static str {
    match stage {
        ShaderStage::Vertex => "vertex",
        ShaderStage::Fragment => "fragment",
        ShaderStage::Compute => "compute",
        ShaderStage::Task => "task",
        ShaderStage::Mesh => "mesh",
    }
}

/// The offline family stores code either as a base64 string (matching every
/// other artifact JSON) or as an integer array; accept both.
fn decode_variant_code(value: &serde_json::Value) -> RhiResult<Vec<u8>> {
    match value {
        serde_json::Value::String(code) => {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD
                .decode(code)
                .map_err(|error| {
                    RhiError::layout_mismatch(format!("invalid shader bytecode: {error}"))
                })
        }
        serde_json::Value::Array(values) => values
            .iter()
            .map(|byte| {
                byte.as_u64()
                    .map(|byte| byte as u8)
                    .ok_or_else(|| RhiError::layout_mismatch("invalid shader bytecode"))
            })
            .collect(),
        _ => Err(RhiError::layout_mismatch("invalid shader bytecode")),
    }
}
