//! glTF 2.0 / GLB import into the runtime's interleaved mesh stream.
//!
//! Ported from `Engine/Sources/AssetPipeline/Import/GLTFImporter.swift`.
//!
//! Swift's `Decodable` structs become `serde` derives, `Array[safe:]` becomes
//! explicit bounds checks, and buffer reads go through one checked helper instead
//! of `withUnsafeBytes { loadUnaligned }`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float3x3, Float4, Float4x4, Quatf, simd_cross, simd_dot, simd_inverse3,
    simd_length, simd_length_squared, simd_normalize, simd_transpose3,
};
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;
use serde::Deserialize;

use crate::asset_pipeline::{
    MeshAnimation, MeshAnimationChannel, MeshAnimationInterpolation, MeshAnimationPath,
    MeshAnimationSampler, MeshAsset, MeshMaterial, MeshNode, MeshNormalTools, MeshSkin,
    MeshSubmesh, MeshTexture, MeshTopologySlice,
};

/// Per-primitive topology using a shared vertex pool with an optional index remap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrimitiveMeshTopology {
    pub triangle_indices: Vec<u32>,
    pub index_remap: Option<Vec<u32>>,
}

impl PrimitiveMeshTopology {
    pub fn new(triangle_indices: Vec<u32>, index_remap: Option<Vec<u32>>) -> Self {
        PrimitiveMeshTopology {
            triangle_indices,
            index_remap,
        }
    }
}

/// Every import failure, one variant per Swift case.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum GLTFImporterError {
    #[error("gltf file not found: {0}")]
    FileNotFound(String),
    #[error("invalid gltf json: {0}")]
    InvalidJson(String),
    #[error("unsupported gltf buffer: {0}")]
    UnsupportedBuffer(String),
    #[error("unsupported gltf primitive mode: {0}")]
    UnsupportedPrimitiveMode(i64),
    #[error("{}", missing_scene_graph_message(.0))]
    MissingSceneGraph(Option<i64>),
    #[error("missing mesh at index {0}")]
    MissingMesh(i64),
    #[error("missing accessor at index {0}")]
    MissingAccessor(i64),
    #[error("invalid accessor: {0}")]
    InvalidAccessor(String),
    #[error("buffer access out of bounds: {0}")]
    OutOfBounds(String),
}

/// Swift appends a second clause when the index is present.
fn missing_scene_graph_message(index: &Option<i64>) -> String {
    match index {
        Some(index) => format!("missing scene graph object at index {index}"),
        None => "missing scene graph".to_string(),
    }
}

/// What [`GLTFImporter::load_with_topology`] returns.
#[derive(Clone, Debug, PartialEq)]
pub struct LoadedGLTF {
    pub mesh: MeshAsset,
    pub topologies: Vec<MeshTopologySlice>,
}

pub struct GLTFImporter;

/// The 4×4 identity Swift passes as `matrix_identity_float4x4`.
fn identity_matrix() -> Float4x4 {
    Float4x4::new_with_columns(
        Float4::new(1.0, 0.0, 0.0, 0.0),
        Float4::new(0.0, 1.0, 0.0, 0.0),
        Float4::new(0.0, 0.0, 1.0, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    )
}

impl GLTFImporter {
    const GLB_MAGIC: u32 = 0x4654_6C67;
    const CHUNK_TYPE_JSON: u32 = 0x4E4F_534A;
    const CHUNK_TYPE_BIN: u32 = 0x004E_4942;

    pub fn load(path: &str) -> Result<MeshAsset, GLTFImporterError> {
        Ok(Self::load_with_topology(path)?.mesh)
    }

    pub fn load_with_topology(path: &str) -> Result<LoadedGLTF, GLTFImporterError> {
        let url = Path::new(path);
        if !url.exists() {
            return Err(GLTFImporterError::FileNotFound(path.to_string()));
        }
        let data =
            std::fs::read(url).map_err(|_| GLTFImporterError::FileNotFound(path.to_string()))?;
        let base_url = url.parent().map(Path::to_path_buf);
        let name = url
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or(path)
            .to_string();
        if Self::is_glb(&data) {
            let (json_data, bin_data) = Self::extract_glb_chunks(&data)?;
            return Self::parse_with_topology_binary(
                &json_data,
                bin_data.as_deref(),
                base_url.as_deref(),
                &name,
            );
        }
        Self::parse_with_topology_bytes(&data, base_url.as_deref(), &name)
    }

    /// Loads a glTF with one vertex pool shared across all primitives, which
    /// reduces position redundancy. Returns the shared positions and one
    /// topology per primitive, with an index remap when one was needed.
    pub fn load_with_shared_vertex_pool(
        path: &str,
    ) -> Result<(Vec<Float3>, Vec<PrimitiveMeshTopology>), GLTFImporterError> {
        let url = Path::new(path);
        if !url.exists() {
            return Err(GLTFImporterError::FileNotFound(path.to_string()));
        }
        let data =
            std::fs::read(url).map_err(|_| GLTFImporterError::FileNotFound(path.to_string()))?;
        let base_url = url.parent().map(Path::to_path_buf);
        if Self::is_glb(&data) {
            let (json_data, bin_data) = Self::extract_glb_chunks(&data)?;
            return Self::parse_with_shared_pool_binary(
                &json_data,
                bin_data.as_deref(),
                base_url.as_deref(),
            );
        }
        Self::parse_with_shared_pool_bytes(&data, base_url.as_deref())
    }

    pub fn parse(data: &[u8], base_url: Option<&Path>) -> Result<MeshAsset, GLTFImporterError> {
        Ok(Self::parse_with_topology_bytes(data, base_url, "")?.mesh)
    }

    pub fn parse_with_topology_bytes(
        data: &[u8],
        base_url: Option<&Path>,
        name: &str,
    ) -> Result<LoadedGLTF, GLTFImporterError> {
        let document = Self::decode_document(data)?;
        let buffers = document
            .buffers
            .iter()
            .map(|buffer| Self::resolve_buffer(buffer, base_url))
            .collect::<Result<Vec<_>, _>>()?;
        Self::build_mesh_with_topology(&document, &buffers, name)
    }

    pub fn parse_with_topology_binary(
        json_data: &[u8],
        bin_buffer: Option<&[u8]>,
        base_url: Option<&Path>,
        name: &str,
    ) -> Result<LoadedGLTF, GLTFImporterError> {
        let document = Self::decode_document(json_data)?;
        let buffers = Self::resolve_glb_buffers(&document, bin_buffer, base_url)?;
        Self::build_mesh_with_topology(&document, &buffers, name)
    }

    pub fn parse_with_shared_pool_bytes(
        data: &[u8],
        base_url: Option<&Path>,
    ) -> Result<(Vec<Float3>, Vec<PrimitiveMeshTopology>), GLTFImporterError> {
        let document = Self::decode_document(data)?;
        let buffers = document
            .buffers
            .iter()
            .map(|buffer| Self::resolve_buffer(buffer, base_url))
            .collect::<Result<Vec<_>, _>>()?;
        Self::build_shared_vertex_pool(&document, &buffers)
    }

    pub fn parse_with_shared_pool_binary(
        json_data: &[u8],
        bin_buffer: Option<&[u8]>,
        base_url: Option<&Path>,
    ) -> Result<(Vec<Float3>, Vec<PrimitiveMeshTopology>), GLTFImporterError> {
        let document = Self::decode_document(json_data)?;
        let buffers = Self::resolve_glb_buffers(&document, bin_buffer, base_url)?;
        Self::build_shared_vertex_pool(&document, &buffers)
    }

    fn decode_document(data: &[u8]) -> Result<GLTFDocument, GLTFImporterError> {
        serde_json::from_slice::<GLTFDocument>(data)
            .map_err(|error| GLTFImporterError::InvalidJson(error.to_string()))
    }

    fn build_mesh_with_topology(
        document: &GLTFDocument,
        buffers: &[Vec<u8>],
        name: &str,
    ) -> Result<LoadedGLTF, GLTFImporterError> {
        let root_nodes = Self::root_node_indices(document);
        if root_nodes.is_empty() {
            return Err(GLTFImporterError::MissingSceneGraph(None));
        }
        let mut builder = MeshBuilder::new(document, buffers);
        for node_index in root_nodes {
            builder.consume_node(node_index, identity_matrix())?;
        }
        builder.make_mesh_with_topology(name)
    }

    fn build_shared_vertex_pool(
        document: &GLTFDocument,
        buffers: &[Vec<u8>],
    ) -> Result<(Vec<Float3>, Vec<PrimitiveMeshTopology>), GLTFImporterError> {
        let root_nodes = Self::root_node_indices(document);
        if root_nodes.is_empty() {
            return Err(GLTFImporterError::MissingSceneGraph(None));
        }
        let mut builder = SharedVertexPoolBuilder::new(document, buffers);
        for node_index in root_nodes {
            builder.consume_node(node_index, identity_matrix())?;
        }
        builder.make_primitives_with_shared_pool()
    }

    fn resolve_glb_buffers(
        document: &GLTFDocument,
        bin_buffer: Option<&[u8]>,
        base_url: Option<&Path>,
    ) -> Result<Vec<Vec<u8>>, GLTFImporterError> {
        let mut resolved = Vec::with_capacity(document.buffers.len());
        for (index, buffer) in document.buffers.iter().enumerate() {
            if buffer.uri.is_none()
                && index == 0
                && let Some(bin) = bin_buffer
            {
                resolved.push(bin.to_vec());
                continue;
            }
            resolved.push(Self::resolve_buffer(buffer, base_url)?);
        }
        Ok(resolved)
    }

    fn is_glb(data: &[u8]) -> bool {
        if data.len() < 4 {
            return false;
        }
        u32::from_le_bytes([data[0], data[1], data[2], data[3]]) == Self::GLB_MAGIC
    }

    fn extract_glb_chunks(data: &[u8]) -> Result<(Vec<u8>, Option<Vec<u8>>), GLTFImporterError> {
        if data.len() < 12 {
            return Err(GLTFImporterError::UnsupportedBuffer(
                "GLB file too short".to_string(),
            ));
        }
        let mut offset = 12usize;
        let mut json_data: Option<Vec<u8>> = None;
        let mut bin_data: Option<Vec<u8>> = None;
        while offset + 8 <= data.len() {
            let chunk_length = u32::from_le_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]) as usize;
            let chunk_type = u32::from_le_bytes([
                data[offset + 4],
                data[offset + 5],
                data[offset + 6],
                data[offset + 7],
            ]);
            offset += 8;
            if offset + chunk_length > data.len() {
                return Err(GLTFImporterError::UnsupportedBuffer(
                    "GLB chunk extends beyond file bounds".to_string(),
                ));
            }
            match chunk_type {
                Self::CHUNK_TYPE_JSON => {
                    json_data = Some(data[offset..(offset + chunk_length)].to_vec());
                }
                Self::CHUNK_TYPE_BIN => {
                    bin_data = Some(data[offset..(offset + chunk_length)].to_vec());
                }
                _ => {}
            }
            offset += chunk_length;
        }
        match json_data {
            Some(json) => Ok((json, bin_data)),
            None => Err(GLTFImporterError::UnsupportedBuffer(
                "GLB file missing JSON chunk".to_string(),
            )),
        }
    }

    fn root_node_indices(document: &GLTFDocument) -> Vec<i64> {
        if let (Some(scene_index), Some(scenes)) = (document.scene, &document.scenes)
            && scene_index >= 0
            && ((scene_index as usize) < scenes.len())
        {
            return scenes[scene_index as usize]
                .nodes
                .clone()
                .unwrap_or_default();
        }
        if let Some(first_nodes) = document
            .scenes
            .as_ref()
            .and_then(|scenes| scenes.first())
            .and_then(|scene| scene.nodes.clone())
            && !first_nodes.is_empty()
        {
            return first_nodes;
        }
        let nodes = document.nodes.clone().unwrap_or_default();
        if nodes.is_empty() {
            return Vec::new();
        }
        let mut children: BTreeSet<i64> = BTreeSet::new();
        for node in &nodes {
            for child in node.children.clone().unwrap_or_default() {
                children.insert(child);
            }
        }
        let roots: Vec<i64> = (0..nodes.len() as i64)
            .filter(|index| !children.contains(index))
            .collect();
        if roots.is_empty() {
            return (0..nodes.len() as i64).collect();
        }
        roots
    }

    fn resolve_buffer(
        buffer: &GLTFBuffer,
        base_url: Option<&Path>,
    ) -> Result<Vec<u8>, GLTFImporterError> {
        let Some(uri) = &buffer.uri else {
            return Err(GLTFImporterError::UnsupportedBuffer(
                "buffer has no URI (use loadWithTopology for GLB files)".to_string(),
            ));
        };
        if uri.starts_with("data:") {
            let Some(comma) = uri.find(',') else {
                return Err(GLTFImporterError::UnsupportedBuffer(
                    "malformed data URI".to_string(),
                ));
            };
            let metadata = &uri[..comma];
            let payload = &uri[(comma + 1)..];
            if metadata.contains(";base64") {
                return base64_decode(payload).ok_or_else(|| {
                    GLTFImporterError::UnsupportedBuffer("invalid base64 data URI".to_string())
                });
            }
            let text = percent_decode(payload).ok_or_else(|| {
                GLTFImporterError::UnsupportedBuffer("invalid percent-encoded data URI".to_string())
            })?;
            return Ok(text.into_bytes());
        }
        let url: PathBuf = match base_url {
            Some(base) => base.join(uri),
            None => PathBuf::from(uri),
        };
        if !url.exists() {
            return Err(GLTFImporterError::FileNotFound(
                url.to_string_lossy().into_owned(),
            ));
        }
        std::fs::read(&url)
            .map_err(|_| GLTFImporterError::FileNotFound(url.to_string_lossy().into_owned()))
    }
}

// MARK: - Bounds-checked scalar reads

/// `Array[safe:]`.
fn get<T>(items: &[T], index: i64) -> Option<&T> {
    if index < 0 {
        return None;
    }
    items.get(index as usize)
}

fn read_u8(data: &[u8], offset: usize) -> Option<u8> {
    data.get(offset).copied()
}

fn read_u16(data: &[u8], offset: usize) -> Option<u16> {
    let bytes = data.get(offset..offset + 2)?;
    Some(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn read_u32(data: &[u8], offset: usize) -> Option<u32> {
    let bytes = data.get(offset..offset + 4)?;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_f32(data: &[u8], offset: usize) -> Option<f32> {
    read_u32(data, offset).map(f32::from_bits)
}

/// The bounds-checked read every accessor goes through, replacing Swift's
/// `readValue(_:from:offset:)` which throws `outOfBounds`.
fn read_value<T>(
    data: &[u8],
    offset: i64,
    width: usize,
    decode: impl FnOnce(usize) -> Option<T>,
) -> Result<T, GLTFImporterError> {
    let out_of_bounds = || {
        GLTFImporterError::OutOfBounds(format!(
            "offset {offset} width {width} exceeds buffer size {}",
            data.len()
        ))
    };
    if offset < 0 || ((offset as usize) + width) > data.len() {
        return Err(out_of_bounds());
    }
    decode(offset as usize).ok_or_else(out_of_bounds)
}

fn byte_width(component_type: i64) -> Result<i64, GLTFImporterError> {
    match component_type {
        5121 => Ok(1),
        5123 => Ok(2),
        5125 | 5126 => Ok(4),
        other => Err(GLTFImporterError::InvalidAccessor(format!(
            "unsupported component type {other}"
        ))),
    }
}

/// Resolves an accessor and its buffer view, applying the same two error
/// messages each Swift reader used.
fn view_data<'a, 'd>(
    document: &'d GLTFDocument,
    buffers: &'a [Vec<u8>],
    index: i64,
    expected_type: &str,
    float_only: bool,
    missing_buffer_message: impl Fn(i64) -> String,
) -> Result<(&'a [u8], &'d GLTFAccessor, &'d GLTFBufferView), GLTFImporterError> {
    let accessor =
        get(&document.accessors, index).ok_or(GLTFImporterError::MissingAccessor(index))?;
    if accessor.type_name != expected_type {
        return Err(GLTFImporterError::InvalidAccessor(format!(
            "expected {expected_type} accessor at index {index}"
        )));
    }
    if float_only && accessor.component_type != 5126 {
        return Err(GLTFImporterError::InvalidAccessor(format!(
            "expected FLOAT component type for accessor {index}"
        )));
    }
    let view = match (accessor.buffer_view, &document.buffer_views) {
        (Some(view_index), Some(views)) => get(views, view_index),
        _ => None,
    };
    let Some(view) = view else {
        return Err(GLTFImporterError::InvalidAccessor(format!(
            "accessor {index} has no bufferView"
        )));
    };
    if !(view.buffer >= 0 && ((view.buffer as usize) < buffers.len())) {
        return Err(GLTFImporterError::InvalidAccessor(missing_buffer_message(
            view.buffer,
        )));
    }
    Ok((&buffers[view.buffer as usize], accessor, view))
}

fn base_offset(accessor: &GLTFAccessor, view: &GLTFBufferView) -> i64 {
    view.byte_offset.unwrap_or(0) + accessor.byte_offset.unwrap_or(0)
}

fn read_float2_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float2>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "VEC2", true, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let stride = view.byte_stride.unwrap_or(8);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        out.push(Float2::new(
            read_value(data, offset, 4, |at| read_f32(data, at))?,
            read_value(data, offset + 4, 4, |at| read_f32(data, at))?,
        ));
    }
    Ok(out)
}

fn read_float_scalar_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<f32>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "SCALAR", true, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let stride = view.byte_stride.unwrap_or(4);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        out.push(read_value(data, base + element * stride, 4, |at| {
            read_f32(data, at)
        })?);
    }
    Ok(out)
}

fn read_float3_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float3>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "VEC3", true, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let stride = view.byte_stride.unwrap_or(12);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        out.push(Float3::new(
            read_value(data, offset, 4, |at| read_f32(data, at))?,
            read_value(data, offset + 4, 4, |at| read_f32(data, at))?,
            read_value(data, offset + 8, 4, |at| read_f32(data, at))?,
        ));
    }
    Ok(out)
}

fn read_float4_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float4>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "VEC4", true, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let stride = view.byte_stride.unwrap_or(16);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        out.push(Float4::new(
            read_value(data, offset, 4, |at| read_f32(data, at))?,
            read_value(data, offset + 4, 4, |at| read_f32(data, at))?,
            read_value(data, offset + 8, 4, |at| read_f32(data, at))?,
            read_value(data, offset + 12, 4, |at| read_f32(data, at))?,
        ));
    }
    Ok(out)
}

/// A SCALAR/VEC3/VEC4 animation output, widened to four lanes.
fn read_animation_output_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float4>, GLTFImporterError> {
    let accessor =
        get(&document.accessors, index).ok_or(GLTFImporterError::MissingAccessor(index))?;
    match accessor.type_name.as_str() {
        "SCALAR" => Ok(read_float_scalar_accessor(document, buffers, index)?
            .into_iter()
            .map(|value| Float4::new(value, 0.0, 0.0, 0.0))
            .collect()),
        "VEC3" => Ok(read_float3_accessor(document, buffers, index)?
            .into_iter()
            .map(|value| Float4::new(value.x, value.y, value.z, 0.0))
            .collect()),
        "VEC4" => read_float4_accessor(document, buffers, index),
        other => Err(GLTFImporterError::InvalidAccessor(format!(
            "unsupported animation output accessor type {other}"
        ))),
    }
}

fn read_float4x4_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float4x4>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "MAT4", true, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let stride = view.byte_stride.unwrap_or(64);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        let mut columns = [Float4::ZERO; 4];
        for (column, slot) in columns.iter_mut().enumerate() {
            let column_offset = offset + (column as i64) * 16;
            *slot = Float4::new(
                read_value(data, column_offset, 4, |at| read_f32(data, at))?,
                read_value(data, column_offset + 4, 4, |at| read_f32(data, at))?,
                read_value(data, column_offset + 8, 4, |at| read_f32(data, at))?,
                read_value(data, column_offset + 12, 4, |at| read_f32(data, at))?,
            );
        }
        out.push(Float4x4::from_columns(columns));
    }
    Ok(out)
}

fn read_joint4_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float4>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "VEC4", false, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let component_size = byte_width(accessor.component_type)?;
    let stride = view.byte_stride.unwrap_or(component_size * 4);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        let value = match accessor.component_type {
            5121 => Float4::new(
                f32::from(read_value(data, offset, 1, |at| read_u8(data, at))?),
                f32::from(read_value(data, offset + 1, 1, |at| read_u8(data, at))?),
                f32::from(read_value(data, offset + 2, 1, |at| read_u8(data, at))?),
                f32::from(read_value(data, offset + 3, 1, |at| read_u8(data, at))?),
            ),
            5123 => Float4::new(
                f32::from(read_value(data, offset, 2, |at| read_u16(data, at))?),
                f32::from(read_value(data, offset + 2, 2, |at| read_u16(data, at))?),
                f32::from(read_value(data, offset + 4, 2, |at| read_u16(data, at))?),
                f32::from(read_value(data, offset + 6, 2, |at| read_u16(data, at))?),
            ),
            other => {
                return Err(GLTFImporterError::InvalidAccessor(format!(
                    "unsupported joint component type {other}"
                )));
            }
        };
        out.push(value);
    }
    Ok(out)
}

fn read_weight4_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<Float4>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "VEC4", false, |buffer| {
        format!("buffer view references missing buffer {buffer}")
    })?;
    let component_size = byte_width(accessor.component_type)?;
    let stride = view.byte_stride.unwrap_or(component_size * 4);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        let value = match accessor.component_type {
            5126 => Float4::new(
                read_value(data, offset, 4, |at| read_f32(data, at))?,
                read_value(data, offset + 4, 4, |at| read_f32(data, at))?,
                read_value(data, offset + 8, 4, |at| read_f32(data, at))?,
                read_value(data, offset + 12, 4, |at| read_f32(data, at))?,
            ),
            5121 => {
                let divisor: f32 = if accessor.normalized == Some(true) {
                    255.0
                } else {
                    1.0
                };
                Float4::new(
                    f32::from(read_value(data, offset, 1, |at| read_u8(data, at))?) / divisor,
                    f32::from(read_value(data, offset + 1, 1, |at| read_u8(data, at))?) / divisor,
                    f32::from(read_value(data, offset + 2, 1, |at| read_u8(data, at))?) / divisor,
                    f32::from(read_value(data, offset + 3, 1, |at| read_u8(data, at))?) / divisor,
                )
            }
            5123 => {
                let divisor: f32 = if accessor.normalized == Some(true) {
                    65_535.0
                } else {
                    1.0
                };
                Float4::new(
                    f32::from(read_value(data, offset, 2, |at| read_u16(data, at))?) / divisor,
                    f32::from(read_value(data, offset + 2, 2, |at| read_u16(data, at))?) / divisor,
                    f32::from(read_value(data, offset + 4, 2, |at| read_u16(data, at))?) / divisor,
                    f32::from(read_value(data, offset + 6, 2, |at| read_u16(data, at))?) / divisor,
                )
            }
            other => {
                return Err(GLTFImporterError::InvalidAccessor(format!(
                    "unsupported weight component type {other}"
                )));
            }
        };
        out.push(value);
    }
    Ok(out)
}

fn read_index_accessor(
    document: &GLTFDocument,
    buffers: &[Vec<u8>],
    index: i64,
) -> Result<Vec<i64>, GLTFImporterError> {
    let (data, accessor, view) = view_data(document, buffers, index, "SCALAR", false, |buffer| {
        format!("accessor {index} references buffer {buffer} which does not exist")
    })?;
    let component_size = byte_width(accessor.component_type)?;
    let stride = view.byte_stride.unwrap_or(component_size);
    let base = base_offset(accessor, view);
    let mut out = Vec::with_capacity(accessor.count.max(0) as usize);
    for element in 0..accessor.count {
        let offset = base + element * stride;
        let value = match accessor.component_type {
            5121 => i64::from(read_value(data, offset, 1, |at| read_u8(data, at))?),
            5123 => i64::from(read_value(data, offset, 2, |at| read_u16(data, at))?),
            5125 => i64::from(read_value(data, offset, 4, |at| read_u32(data, at))?),
            other => {
                return Err(GLTFImporterError::InvalidAccessor(format!(
                    "unsupported index component type {other}"
                )));
            }
        };
        out.push(value);
    }
    Ok(out)
}

// MARK: - Mesh builder

struct MeshBuilder<'a> {
    document: &'a GLTFDocument,
    buffers: &'a [Vec<u8>],
    vertices: Vec<f32>,
    indices: Vec<u32>,
    next_index: u32,
    topologies: Vec<MeshTopologySlice>,
    submeshes: Vec<MeshSubmesh>,
}

impl<'a> MeshBuilder<'a> {
    fn new(document: &'a GLTFDocument, buffers: &'a [Vec<u8>]) -> Self {
        MeshBuilder {
            document,
            buffers,
            vertices: Vec::new(),
            indices: Vec::new(),
            next_index: 0,
            topologies: Vec::new(),
            submeshes: Vec::new(),
        }
    }

    fn consume_node(
        &mut self,
        index: i64,
        parent_transform: Float4x4,
    ) -> Result<(), GLTFImporterError> {
        let Some(node) = self
            .document
            .nodes
            .as_ref()
            .and_then(|nodes| get(nodes, index))
        else {
            return Err(GLTFImporterError::MissingSceneGraph(Some(index)));
        };
        let world_transform = parent_transform * node.local_transform();
        let children = node.children.clone().unwrap_or_default();
        let mesh = node.mesh;
        if let Some(mesh_index) = mesh {
            self.consume_mesh(mesh_index, world_transform)?;
        }
        for child in children {
            self.consume_node(child, world_transform)?;
        }
        Ok(())
    }

    fn consume_mesh(&mut self, index: i64, transform: Float4x4) -> Result<(), GLTFImporterError> {
        let Some(mesh) = self
            .document
            .meshes
            .as_ref()
            .and_then(|meshes| get(meshes, index))
        else {
            return Err(GLTFImporterError::MissingMesh(index));
        };
        let document = self.document;
        let buffers = self.buffers;
        for primitive in &mesh.primitives {
            let mode = primitive.mode.unwrap_or(4);
            if mode != 4 {
                return Err(GLTFImporterError::UnsupportedPrimitiveMode(mode));
            }
            let Some(position_accessor) = primitive.attributes.get("POSITION").copied() else {
                return Err(GLTFImporterError::InvalidAccessor(
                    "primitive missing POSITION attribute".to_string(),
                ));
            };

            let positions = read_float3_accessor(document, buffers, position_accessor)?;
            let normals = match primitive.attributes.get("NORMAL").copied() {
                Some(value) => Some(read_float3_accessor(document, buffers, value)?),
                None => None,
            };
            let uvs = match primitive.attributes.get("TEXCOORD_0").copied() {
                Some(value) => Some(read_float2_accessor(document, buffers, value)?),
                None => None,
            };
            let tangents = match primitive.attributes.get("TANGENT").copied() {
                Some(value) => Some(read_float4_accessor(document, buffers, value)?),
                None => None,
            };
            let joints = match primitive.attributes.get("JOINTS_0").copied() {
                Some(value) => Some(read_joint4_accessor(document, buffers, value)?),
                None => None,
            };
            let weights = match primitive.attributes.get("WEIGHTS_0").copied() {
                Some(value) => Some(read_weight4_accessor(document, buffers, value)?),
                None => None,
            };
            let primitive_material_index = primitive.material.unwrap_or(0);
            let material_index = primitive_material_index as f32;
            let primitive_indices = match primitive.indices {
                Some(value) => read_index_accessor(document, buffers, value)?,
                None => (0..positions.len() as i64).collect(),
            };

            let submesh_index_start = self.indices.len() as u32;

            let topology_positions: Vec<Float3> = positions
                .iter()
                .map(|local| {
                    let p = transform * Float4::new(local.x, local.y, local.z, 1.0);
                    Float3::new(p.x, p.y, p.z)
                })
                .collect();
            let topology_indices: Vec<u32> = primitive_indices
                .iter()
                .map(|index| *index as u32)
                .collect();
            self.topologies.push(MeshTopologySlice::new(
                topology_positions.clone(),
                topology_indices,
                None,
            ));

            // Swift recomputes the normal matrix as transpose(inverse(basis)),
            // where `basis` is the transform's upper-left 3×3.
            let basis = Float3x3::from_columns([
                Float3::new(
                    transform.column(0).x,
                    transform.column(0).y,
                    transform.column(0).z,
                ),
                Float3::new(
                    transform.column(1).x,
                    transform.column(1).y,
                    transform.column(1).z,
                ),
                Float3::new(
                    transform.column(2).x,
                    transform.column(2).y,
                    transform.column(2).z,
                ),
            ]);
            let normal_matrix = simd_transpose3(simd_inverse3(basis));

            // Generate tangents when the glTF omits the TANGENT attribute.
            // Without a valid tangent frame the normal map cannot be applied, so
            // all surface microdetail (brushing, engraving, scratches) is lost
            // and a textured metal renders like a smooth grey model.
            let generated_tangents: Option<Vec<Float4>> = match (&tangents, &uvs, &normals) {
                (None, Some(uvs), Some(normals)) => {
                    let world_normals: Vec<Float3> = normals
                        .iter()
                        .map(|n| {
                            let transformed = normal_matrix * *n;
                            if simd_length_squared(transformed) > 0.0 {
                                simd_normalize(transformed)
                            } else {
                                Float3::new(0.0, 0.0, 1.0)
                            }
                        })
                        .collect();
                    Some(generate_tangents(
                        &primitive_indices,
                        &topology_positions,
                        uvs,
                        &world_normals,
                    ))
                }
                _ => None,
            };

            for (vertex_slot, raw_index) in primitive_indices.iter().enumerate() {
                if !(*raw_index >= 0 && ((*raw_index as usize) < positions.len())) {
                    return Err(GLTFImporterError::OutOfBounds(format!(
                        "position index {raw_index} out of range"
                    )));
                }
                let local_position = positions[*raw_index as usize];
                let world_position4 = transform
                    * Float4::new(local_position.x, local_position.y, local_position.z, 1.0);
                let world_position =
                    Float3::new(world_position4.x, world_position4.y, world_position4.z);

                let world_normal = match &normals {
                    Some(normals) if (*raw_index as usize) < normals.len() => {
                        let transformed = normal_matrix * normals[*raw_index as usize];
                        if simd_length_squared(transformed) > 0.0 {
                            simd_normalize(transformed)
                        } else {
                            Float3::ZERO
                        }
                    }
                    _ => Float3::ZERO,
                };

                let uv = uvs
                    .as_ref()
                    .and_then(|uvs| uvs.get(*raw_index as usize).copied())
                    .unwrap_or(Float2::ZERO);
                let tangent = generated_tangents
                    .as_ref()
                    .and_then(|tangents| tangents.get(vertex_slot).copied())
                    .or_else(|| {
                        tangents
                            .as_ref()
                            .and_then(|tangents| tangents.get(*raw_index as usize).copied())
                    })
                    .unwrap_or(Float4::new(1.0, 0.0, 0.0, 1.0));
                let joint = joints
                    .as_ref()
                    .and_then(|joints| joints.get(*raw_index as usize).copied())
                    .unwrap_or(Float4::ZERO);
                let weight = weights
                    .as_ref()
                    .and_then(|weights| weights.get(*raw_index as usize).copied())
                    .unwrap_or(Float4::new(1.0, 0.0, 0.0, 0.0));

                MeshAsset::append_vertex(
                    &mut self.vertices,
                    world_position,
                    world_normal,
                    Float3::new(1.0, 1.0, 1.0),
                    uv,
                    tangent,
                    material_index,
                    joint,
                    weight,
                );
                self.indices.push(self.next_index);
                self.next_index += 1;
            }
            let submesh_index_count = self.indices.len() as u32 - submesh_index_start;
            self.submeshes.push(MeshSubmesh::new(
                submesh_index_start,
                submesh_index_count,
                primitive_material_index,
            ));
        }
        Ok(())
    }

    #[allow(clippy::type_complexity)]
    fn make_mesh_with_topology(mut self, name: &str) -> Result<LoadedGLTF, GLTFImporterError> {
        if self.vertices.is_empty() {
            return Err(GLTFImporterError::InvalidAccessor(
                "gltf produced no triangles".to_string(),
            ));
        }
        let materials = self.document.mesh_materials();
        let textures = self.document.mesh_textures(self.buffers);
        let nodes = self.mesh_nodes();
        let skins = self.mesh_skins()?;
        let animations = self.mesh_animations()?;
        let mut mesh = MeshAsset {
            materials,
            textures,
            nodes,
            skins,
            animations,
            submeshes: std::mem::take(&mut self.submeshes),
            ..MeshAsset::new(
                name.to_string(),
                std::mem::take(&mut self.vertices),
                std::mem::take(&mut self.indices),
            )
        };
        MeshNormalTools::fill_missing_normals(&mut mesh.vertices, &mesh.indices);
        Ok(LoadedGLTF {
            mesh,
            topologies: std::mem::take(&mut self.topologies),
        })
    }

    fn mesh_nodes(&self) -> Vec<MeshNode> {
        let Some(nodes) = &self.document.nodes else {
            return Vec::new();
        };
        if nodes.is_empty() {
            return Vec::new();
        }
        // Child → parent index.
        let mut parent_of: BTreeMap<i64, i64> = BTreeMap::new();
        for (index, node) in nodes.iter().enumerate() {
            for child in node.children.clone().unwrap_or_default() {
                parent_of.insert(child, index as i64);
            }
        }
        nodes
            .iter()
            .enumerate()
            .map(|(index, node)| {
                let (translation, rotation, scale) = match &node.matrix {
                    Some(matrix) if matrix.len() == 16 => {
                        // Decompose the column-major matrix.
                        let col0 = Float3::new(matrix[0], matrix[1], matrix[2]);
                        let col1 = Float3::new(matrix[4], matrix[5], matrix[6]);
                        let col2 = Float3::new(matrix[8], matrix[9], matrix[10]);
                        let translation = Float3::new(matrix[12], matrix[13], matrix[14]);
                        let scale =
                            Float3::new(simd_length(col0), simd_length(col1), simd_length(col2));
                        let rx = col0 / scale.x.max(1e-6);
                        let ry = col1 / scale.y.max(1e-6);
                        let rz = col2 / scale.z.max(1e-6);
                        let q = Quatf::from_float3x3(Float3x3::from_columns([rx, ry, rz]));
                        (
                            translation,
                            Float4::new(q.imag().x, q.imag().y, q.imag().z, q.real()),
                            scale,
                        )
                    }
                    _ => {
                        let translation = match &node.translation {
                            Some(values) if values.len() == 3 => {
                                Float3::new(values[0], values[1], values[2])
                            }
                            _ => Float3::ZERO,
                        };
                        let rotation = match &node.rotation {
                            Some(values) if values.len() == 4 => {
                                Float4::new(values[0], values[1], values[2], values[3])
                            }
                            _ => Float4::new(0.0, 0.0, 0.0, 1.0),
                        };
                        let scale = match &node.scale {
                            Some(values) if values.len() == 3 => {
                                Float3::new(values[0], values[1], values[2])
                            }
                            _ => Float3::ONE,
                        };
                        (translation, rotation, scale)
                    }
                };
                MeshNode {
                    name: node.name.clone(),
                    parent_index: parent_of.get(&(index as i64)).copied(),
                    local_translation: translation,
                    local_rotation: rotation,
                    local_scale: scale,
                }
            })
            .collect()
    }

    fn mesh_skins(&self) -> Result<Vec<MeshSkin>, GLTFImporterError> {
        let Some(skins) = &self.document.skins else {
            return Ok(Vec::new());
        };
        let mut out = Vec::with_capacity(skins.len());
        for skin in skins {
            let inverse_bind_matrices = match skin.inverse_bind_matrices {
                Some(accessor_index) => {
                    read_float4x4_accessor(self.document, self.buffers, accessor_index)?
                }
                None => vec![identity_matrix(); skin.joints.len()],
            };
            out.push(MeshSkin {
                name: skin.name.clone(),
                joint_node_indices: skin.joints.clone(),
                inverse_bind_matrices,
            });
        }
        Ok(out)
    }

    fn mesh_animations(&self) -> Result<Vec<MeshAnimation>, GLTFImporterError> {
        let Some(animations) = &self.document.animations else {
            return Ok(Vec::new());
        };
        let mut out = Vec::with_capacity(animations.len());
        for animation in animations {
            let mut samplers = Vec::with_capacity(animation.samplers.len());
            for sampler in &animation.samplers {
                samplers.push(MeshAnimationSampler {
                    input_times: read_float_scalar_accessor(
                        self.document,
                        self.buffers,
                        sampler.input,
                    )?,
                    output_values: read_animation_output_accessor(
                        self.document,
                        self.buffers,
                        sampler.output,
                    )?,
                    interpolation: interpolation_from_gltf(sampler.interpolation.as_deref()),
                });
            }
            let mut channels = Vec::with_capacity(animation.channels.len());
            for channel in &animation.channels {
                let Some(path) = path_from_gltf(&channel.target.path) else {
                    return Err(GLTFImporterError::InvalidAccessor(format!(
                        "unsupported animation target path {}",
                        channel.target.path
                    )));
                };
                channels.push(MeshAnimationChannel {
                    sampler_index: channel.sampler,
                    target_node_index: channel.target.node,
                    path,
                });
            }
            out.push(MeshAnimation {
                name: animation.name.clone(),
                samplers,
                channels,
            });
        }
        Ok(out)
    }
}

/// Swift's `MeshAnimationInterpolation(gltfName:)`.
fn interpolation_from_gltf(name: Option<&str>) -> MeshAnimationInterpolation {
    match name {
        Some("STEP") => MeshAnimationInterpolation::Step,
        Some("CUBICSPLINE") => MeshAnimationInterpolation::CubicSpline,
        _ => MeshAnimationInterpolation::Linear,
    }
}

/// Swift's `MeshAnimationPath(rawValue:)`.
fn path_from_gltf(value: &str) -> Option<MeshAnimationPath> {
    match value {
        "translation" => Some(MeshAnimationPath::Translation),
        "rotation" => Some(MeshAnimationPath::Rotation),
        "scale" => Some(MeshAnimationPath::Scale),
        "weights" => Some(MeshAnimationPath::Weights),
        _ => None,
    }
}

// MARK: - Shared vertex pool builder

struct SharedVertexPoolBuilder<'a> {
    document: &'a GLTFDocument,
    buffers: &'a [Vec<u8>],
    shared_positions: Vec<Float3>,
    primitives: Vec<PrimitiveMeshTopology>,
    position_to_shared_index: HashMap<String, u32>,
}

impl<'a> SharedVertexPoolBuilder<'a> {
    fn new(document: &'a GLTFDocument, buffers: &'a [Vec<u8>]) -> Self {
        SharedVertexPoolBuilder {
            document,
            buffers,
            shared_positions: Vec::new(),
            primitives: Vec::new(),
            position_to_shared_index: HashMap::new(),
        }
    }

    fn consume_node(
        &mut self,
        index: i64,
        parent_transform: Float4x4,
    ) -> Result<(), GLTFImporterError> {
        let Some(node) = self
            .document
            .nodes
            .as_ref()
            .and_then(|nodes| get(nodes, index))
        else {
            return Err(GLTFImporterError::MissingSceneGraph(Some(index)));
        };
        let world_transform = parent_transform * node.local_transform();
        let children = node.children.clone().unwrap_or_default();
        let mesh = node.mesh;
        if let Some(mesh_index) = mesh {
            self.consume_mesh(mesh_index, world_transform)?;
        }
        for child in children {
            self.consume_node(child, world_transform)?;
        }
        Ok(())
    }

    fn consume_mesh(&mut self, index: i64, transform: Float4x4) -> Result<(), GLTFImporterError> {
        let Some(mesh) = self
            .document
            .meshes
            .as_ref()
            .and_then(|meshes| get(meshes, index))
        else {
            return Err(GLTFImporterError::MissingMesh(index));
        };
        for primitive in &mesh.primitives {
            let mode = primitive.mode.unwrap_or(4);
            if mode != 4 {
                return Err(GLTFImporterError::UnsupportedPrimitiveMode(mode));
            }
            let Some(position_accessor) = primitive.attributes.get("POSITION").copied() else {
                return Err(GLTFImporterError::InvalidAccessor(
                    "primitive missing POSITION attribute".to_string(),
                ));
            };
            let positions = read_float3_accessor(self.document, self.buffers, position_accessor)?;
            let primitive_indices = match primitive.indices {
                Some(value) => read_index_accessor(self.document, self.buffers, value)?,
                None => (0..positions.len() as i64).collect(),
            };

            let mut remapped_indices: Vec<u32> = Vec::new();
            let mut remap_needed = false;

            for raw_index in &primitive_indices {
                if !(*raw_index >= 0 && ((*raw_index as usize) < positions.len())) {
                    return Err(GLTFImporterError::OutOfBounds(format!(
                        "position index {raw_index} out of range"
                    )));
                }
                let local_position = positions[*raw_index as usize];
                let world_position4 = transform
                    * Float4::new(local_position.x, local_position.y, local_position.z, 1.0);
                let world_position =
                    Float3::new(world_position4.x, world_position4.y, world_position4.z);
                let key = format!(
                    "{},{},{}",
                    world_position.x, world_position.y, world_position.z
                );
                let assigned = match self.position_to_shared_index.get(&key) {
                    Some(existing) => *existing,
                    None => {
                        let new_index = self.shared_positions.len() as u32;
                        self.shared_positions.push(world_position);
                        self.position_to_shared_index.insert(key, new_index);
                        new_index
                    }
                };
                remapped_indices.push(assigned);
                if (*raw_index as u32) != assigned {
                    remap_needed = true;
                }
            }

            let index_remap = if remap_needed {
                Some(
                    primitive_indices
                        .iter()
                        .map(|element| *element as u32)
                        .collect(),
                )
            } else {
                None
            };
            self.primitives
                .push(PrimitiveMeshTopology::new(remapped_indices, index_remap));
        }
        Ok(())
    }

    fn make_primitives_with_shared_pool(
        self,
    ) -> Result<(Vec<Float3>, Vec<PrimitiveMeshTopology>), GLTFImporterError> {
        if self.shared_positions.is_empty() {
            return Err(GLTFImporterError::InvalidAccessor(
                "gltf produced no vertices in shared pool".to_string(),
            ));
        }
        Ok((self.shared_positions, self.primitives))
    }
}

// MARK: - Tangents

/// Per-vertex tangents for an expanded (non-indexed) triangle list, computed
/// from positions and UVs (Lengyel's method) and orthonormalized against each
/// vertex normal. `world_positions`/`world_normals` must be in the same space as
/// the stored vertex normals. Returns one tangent (xyz plus handedness in w) per
/// entry of `primitive_indices`.
fn generate_tangents(
    primitive_indices: &[i64],
    world_positions: &[Float3],
    uvs: &[Float2],
    world_normals: &[Float3],
) -> Vec<Float4> {
    let mut out = vec![Float4::new(1.0, 0.0, 0.0, 1.0); primitive_indices.len()];
    let mut t = 0usize;
    while t + 2 < primitive_indices.len() {
        let ia = primitive_indices[t];
        let ib = primitive_indices[t + 1];
        let ic = primitive_indices[t + 2];
        let in_range = |index: i64| index >= 0 && ((index as usize) < world_positions.len());
        if !(in_range(ia) && in_range(ib) && in_range(ic))
            || !(in_range(ia) && in_range(ib) && in_range(ic))
            || !(ia < uvs.len() as i64 && ib < uvs.len() as i64 && ic < uvs.len() as i64)
        {
            t += 3;
            continue;
        }
        let p0 = world_positions[ia as usize];
        let p1 = world_positions[ib as usize];
        let p2 = world_positions[ic as usize];
        let w0 = uvs[ia as usize];
        let w1 = uvs[ib as usize];
        let w2 = uvs[ic as usize];
        let e1 = p1 - p0;
        let e2 = p2 - p0;
        let du1 = w1 - w0;
        let du2 = w2 - w0;
        let denom = du1.x * du2.y - du2.x * du1.y;
        let r: f32 = if denom.abs() > 1e-9 { 1.0 / denom } else { 0.0 };
        let face_t = (e1 * du2.y - e2 * du1.y) * r;
        let face_b = (e2 * du1.x - e1 * du2.x) * r;
        for (slot, vertex_index) in [(t, ia), (t + 1, ib), (t + 2, ic)] {
            let n = if in_range(vertex_index)
                && simd_length_squared(world_normals[vertex_index as usize]) > 0.0
            {
                simd_normalize(world_normals[vertex_index as usize])
            } else {
                Float3::new(0.0, 0.0, 1.0)
            };
            // Gram-Schmidt against the normal.
            let mut tan = face_t - n * simd_dot(n, face_t);
            if simd_length_squared(tan) < 1e-12 {
                let helper = if n.x.abs() < 0.9 {
                    Float3::new(1.0, 0.0, 0.0)
                } else {
                    Float3::new(0.0, 1.0, 0.0)
                };
                tan = helper - n * simd_dot(n, helper);
            }
            tan = if simd_length_squared(tan) > 0.0 {
                simd_normalize(tan)
            } else {
                Float3::new(1.0, 0.0, 0.0)
            };
            let handedness: f32 = if simd_dot(simd_cross(n, tan), face_b) < 0.0 {
                -1.0
            } else {
                1.0
            };
            out[slot] = Float4::new(tan.x, tan.y, tan.z, handedness);
        }
        t += 3;
    }
    out
}

// MARK: - glTF document

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GLTFDocument {
    scene: Option<i64>,
    scenes: Option<Vec<GLTFScene>>,
    nodes: Option<Vec<GLTFNode>>,
    meshes: Option<Vec<GLTFMesh>>,
    materials: Option<Vec<GLTFMaterial>>,
    textures: Option<Vec<GLTFTexture>>,
    images: Option<Vec<GLTFImage>>,
    // Swift declares `samplers` here but never reads it; serde ignores unknown
    // keys exactly as `Decodable` does, so omitting it changes no behaviour.
    skins: Option<Vec<GLTFSkin>>,
    animations: Option<Vec<GLTFAnimation>>,
    accessors: Vec<GLTFAccessor>,
    buffer_views: Option<Vec<GLTFBufferView>>,
    buffers: Vec<GLTFBuffer>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFScene {
    nodes: Option<Vec<i64>>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFNode {
    name: Option<String>,
    mesh: Option<i64>,
    // `skin` is declared by Swift's node schema but never read.
    children: Option<Vec<i64>>,
    matrix: Option<Vec<f32>>,
    translation: Option<Vec<f32>>,
    rotation: Option<Vec<f32>>,
    scale: Option<Vec<f32>>,
}

impl GLTFNode {
    fn local_transform(&self) -> Float4x4 {
        if let Some(matrix) = &self.matrix
            && matrix.len() == 16
        {
            return Float4x4::from_columns([
                Float4::new(matrix[0], matrix[1], matrix[2], matrix[3]),
                Float4::new(matrix[4], matrix[5], matrix[6], matrix[7]),
                Float4::new(matrix[8], matrix[9], matrix[10], matrix[11]),
                Float4::new(matrix[12], matrix[13], matrix[14], matrix[15]),
            ]);
        }
        let t = translation_vector(self.translation.as_deref());
        let s = scale_vector(self.scale.as_deref());
        let r = rotation_quaternion(self.rotation.as_deref());
        let translation_matrix = Float4x4::new_with_columns(
            Float4::new(1.0, 0.0, 0.0, 0.0),
            Float4::new(0.0, 1.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 1.0, 0.0),
            Float4::new(t.x, t.y, t.z, 1.0),
        );
        let rotation_matrix = Float4x4::from_quatf(r);
        let scale_matrix = Float4x4::new_with_columns(
            Float4::new(s.x, 0.0, 0.0, 0.0),
            Float4::new(0.0, s.y, 0.0, 0.0),
            Float4::new(0.0, 0.0, s.z, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        );
        translation_matrix * rotation_matrix * scale_matrix
    }
}

fn translation_vector(source: Option<&[f32]>) -> Float3 {
    match source {
        Some(values) if values.len() == 3 => Float3::new(values[0], values[1], values[2]),
        _ => Float3::ZERO,
    }
}

fn scale_vector(source: Option<&[f32]>) -> Float3 {
    match source {
        Some(values) if values.len() == 3 => Float3::new(values[0], values[1], values[2]),
        _ => Float3::new(1.0, 1.0, 1.0),
    }
}

/// Swift falls back to `simd_quatf(angle: 0, axis: (0,1,0))`, i.e. identity.
fn rotation_quaternion(source: Option<&[f32]>) -> Quatf {
    match source {
        Some(values) if values.len() == 4 => {
            Quatf::from_parts(values[0], values[1], values[2], values[3])
        }
        _ => Quatf::IDENTITY,
    }
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFMesh {
    primitives: Vec<GLTFPrimitive>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFPrimitive {
    attributes: HashMap<String, i64>,
    indices: Option<i64>,
    mode: Option<i64>,
    material: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFMaterial {
    name: Option<String>,
    #[serde(rename = "pbrMetallicRoughness")]
    pbr_metallic_roughness: Option<GLTFPBRMetallicRoughness>,
    #[serde(rename = "normalTexture")]
    normal_texture: Option<GLTFTextureInfo>,
    #[serde(rename = "alphaMode")]
    alpha_mode: Option<MaterialAlphaMode>,
    #[serde(rename = "alphaCutoff")]
    alpha_cutoff: Option<f32>,
    #[serde(rename = "doubleSided")]
    double_sided: Option<bool>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFPBRMetallicRoughness {
    #[serde(rename = "baseColorFactor")]
    base_color_factor: Option<Vec<f32>>,
    #[serde(rename = "baseColorTexture")]
    base_color_texture: Option<GLTFTextureInfo>,
    #[serde(rename = "metallicRoughnessTexture")]
    metallic_roughness_texture: Option<GLTFTextureInfo>,
    #[serde(rename = "metallicFactor")]
    metallic_factor: Option<f32>,
    #[serde(rename = "roughnessFactor")]
    roughness_factor: Option<f32>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFTextureInfo {
    index: i64,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFTexture {
    name: Option<String>,
    sampler: Option<i64>,
    source: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFImage {
    name: Option<String>,
    uri: Option<String>,
    #[serde(rename = "bufferView")]
    buffer_view: Option<i64>,
    #[serde(rename = "mimeType")]
    mime_type: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFSkin {
    name: Option<String>,
    #[serde(rename = "inverseBindMatrices")]
    inverse_bind_matrices: Option<i64>,
    // Swift declares `skeleton` but never reads it.
    joints: Vec<i64>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFAnimation {
    name: Option<String>,
    samplers: Vec<GLTFAnimationSampler>,
    channels: Vec<GLTFAnimationChannel>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFAnimationSampler {
    input: i64,
    output: i64,
    interpolation: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFAnimationChannel {
    sampler: i64,
    target: GLTFAnimationTarget,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFAnimationTarget {
    node: Option<i64>,
    path: String,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFAccessor {
    #[serde(rename = "bufferView")]
    buffer_view: Option<i64>,
    #[serde(rename = "byteOffset")]
    byte_offset: Option<i64>,
    #[serde(rename = "componentType")]
    component_type: i64,
    count: i64,
    #[serde(rename = "type")]
    type_name: String,
    normalized: Option<bool>,
}

#[derive(Clone, Debug, Deserialize)]
struct GLTFBufferView {
    buffer: i64,
    #[serde(rename = "byteOffset")]
    byte_offset: Option<i64>,
    #[serde(rename = "byteLength")]
    byte_length: i64,
    #[serde(rename = "byteStride")]
    byte_stride: Option<i64>,
}

/// Buffer sizing uses the actual bytes read, exactly as Swift's `Data` did, so
/// `byteLength` is not read.
#[derive(Clone, Debug, Deserialize)]
struct GLTFBuffer {
    uri: Option<String>,
}

impl GLTFDocument {
    fn mesh_materials(&self) -> Vec<MeshMaterial> {
        let Some(materials) = &self.materials else {
            return vec![MeshMaterial::fallback()];
        };
        if materials.is_empty() {
            return vec![MeshMaterial::fallback()];
        }
        materials
            .iter()
            .map(|material| {
                let pbr = &material.pbr_metallic_roughness;
                MeshMaterial::new(
                    material.name.clone(),
                    vec4(
                        pbr.as_ref()
                            .and_then(|pbr| pbr.base_color_factor.as_deref()),
                        Float4::new(1.0, 1.0, 1.0, 1.0),
                    ),
                    pbr.as_ref()
                        .and_then(|pbr| pbr.base_color_texture.as_ref())
                        .map(|texture| texture.index),
                    material
                        .normal_texture
                        .as_ref()
                        .map(|texture| texture.index),
                    pbr.as_ref()
                        .and_then(|pbr| pbr.metallic_roughness_texture.as_ref())
                        .map(|texture| texture.index),
                    pbr.as_ref()
                        .and_then(|pbr| pbr.metallic_factor)
                        .unwrap_or(1.0),
                    pbr.as_ref()
                        .and_then(|pbr| pbr.roughness_factor)
                        .unwrap_or(1.0),
                    material.alpha_mode.unwrap_or(MaterialAlphaMode::Opaque),
                    material.alpha_cutoff.unwrap_or(0.5),
                    material.double_sided.unwrap_or(false),
                )
            })
            .collect()
    }

    fn mesh_textures(&self, buffers: &[Vec<u8>]) -> Vec<MeshTexture> {
        let Some(textures) = &self.textures else {
            return Vec::new();
        };
        if textures.is_empty() {
            return Vec::new();
        }
        textures
            .iter()
            .map(|texture| {
                let image = texture
                    .source
                    .and_then(|source| self.images.as_ref().and_then(|images| get(images, source)));
                let data = image
                    .and_then(|image| image.buffer_view)
                    .and_then(|view| self.image_data(view, buffers));
                MeshTexture {
                    name: texture
                        .name
                        .clone()
                        .or_else(|| image.and_then(|image| image.name.clone())),
                    source_uri: image.and_then(|image| image.uri.clone()),
                    mime_type: image.and_then(|image| image.mime_type.clone()),
                    sampler_index: texture.sampler,
                    data,
                }
            })
            .collect()
    }

    fn image_data(&self, buffer_view_index: i64, buffers: &[Vec<u8>]) -> Option<Vec<u8>> {
        let view = self
            .buffer_views
            .as_ref()
            .and_then(|views| get(views, buffer_view_index))?;
        let buffer = get(buffers, view.buffer)?;
        let start = view.byte_offset.unwrap_or(0);
        let end = start + view.byte_length;
        if start < 0 || end > buffer.len() as i64 {
            return None;
        }
        Some(buffer[start as usize..end as usize].to_vec())
    }
}

/// Swift's `Self.vec4(_:fallback:)`, which needs at least four lanes.
fn vec4(values: Option<&[f32]>, fallback: Float4) -> Float4 {
    match values {
        Some(values) if values.len() >= 4 => {
            Float4::new(values[0], values[1], values[2], values[3])
        }
        _ => fallback,
    }
}

// MARK: - Percent and base64 decoding

/// `String.removingPercentEncoding`: `None` when an escape is malformed.
fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = hex_value(*bytes.get(index + 1)?)?;
            let low = hex_value(*bytes.get(index + 2)?)?;
            out.push((high << 4) | low);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// Standard base64 with padding, matching `Data(base64Encoded:)` without options.
fn base64_decode(value: &str) -> Option<Vec<u8>> {
    fn sextet(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes = value.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let padding = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 {
            return None;
        }
        let mut buffer: u32 = 0;
        for (index, byte) in chunk.iter().enumerate() {
            let digit = if *byte == b'=' {
                if index < 4 - padding {
                    return None;
                }
                0
            } else {
                sextet(*byte)?
            };
            buffer = (buffer << 6) | u32::from(digit);
        }
        out.push((buffer >> 16) as u8);
        if padding < 2 {
            out.push((buffer >> 8) as u8);
        }
        if padding < 1 {
            out.push(buffer as u8);
        }
    }
    Some(out)
}
