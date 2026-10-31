//! Ported from `Engine/Tests/AssetPipelineTests/GLTFImporterTests.swift`.

use diffuse_assets::asset_pipeline::{MeshAsset, MeshTexture};
use diffuse_assets::import::gltf_importer::GLTFImporter;
use diffuse_assets::import::mesh_texture_resolver::MeshTextureResolver;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;
use std::path::{Path, PathBuf};

fn temp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let root = std::env::temp_dir().join(format!("gltf-{tag}-{nanos}"));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn push_f32(values: &[f32], out: &mut Vec<u8>) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn push_u16(values: &[u16], out: &mut Vec<u8>) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = chunk.get(1).copied().unwrap_or(0);
        let third = chunk.get(2).copied().unwrap_or(0);
        out.push(ALPHABET[(first >> 2) as usize] as char);
        out.push(ALPHABET[(((first & 0x03) << 4) | (second >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(((second & 0x0f) << 2) | (third >> 6)) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[(third & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    out
}

fn write_triangle(directory: &Path, name: &str, node_json: &str) -> PathBuf {
    let mut buffer: Vec<u8> = Vec::new();
    push_f32(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0], &mut buffer);
    push_f32(&[0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0], &mut buffer);
    push_u16(&[0, 1, 2], &mut buffer);
    std::fs::write(directory.join(format!("{name}.bin")), &buffer).unwrap();
    let json = format!(
        r#"{{
  "asset": {{ "version": "2.0" }},
  "buffers": [ {{ "uri": "{name}.bin", "byteLength": 78 }} ],
  "bufferViews": [
    {{ "buffer": 0, "byteOffset": 0, "byteLength": 36 }},
    {{ "buffer": 0, "byteOffset": 36, "byteLength": 36 }},
    {{ "buffer": 0, "byteOffset": 72, "byteLength": 6 }}
  ],
  "accessors": [
    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
    {{ "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" }},
    {{ "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }}
  ],
  "meshes": [ {{ "primitives": [ {{ "attributes": {{ "POSITION": 0, "NORMAL": 1 }}, "indices": 2 }} ] }} ],
  "nodes": [ {node_json} ],
  "scenes": [ {{ "nodes": [0] }} ],
  "scene": 0
}}"#
    );
    let path = directory.join(format!("{name}.gltf"));
    std::fs::write(&path, json).unwrap();
    path
}

// Imports glTF alpha coverage, cutoff and sidedness with spec defaults.
#[test]
fn alpha_materials() {
    let root = temp_dir("alpha");
    let mut buffer: Vec<u8> = Vec::new();
    push_f32(
        &[-1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0],
        &mut buffer,
    );
    let json = format!(
        r#"{{"asset":{{"version":"2.0"}},
 "buffers":[{{"uri":"data:application/octet-stream;base64,{}","byteLength":36}}],
 "bufferViews":[{{"buffer":0,"byteLength":36}}],
 "accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}}],
 "materials":[{{}}, {{"alphaMode":"MASK","alphaCutoff":0.3,"doubleSided":true}},
               {{"alphaMode":"BLEND","pbrMetallicRoughness":{{"baseColorFactor":[1,1,1,0.25]}}}}],
 "meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"material":1}}]}}],
 "nodes":[{{"mesh":0}}],"scenes":[{{"nodes":[0]}}],"scene":0}}"#,
        base64(&buffer)
    );
    let path = root.join("alpha.gltf");
    std::fs::write(&path, json).unwrap();
    let mesh = GLTFImporter::load(&path.to_string_lossy()).unwrap();
    assert_eq!(mesh.materials[0].alpha_mode, MaterialAlphaMode::Opaque);
    assert_eq!(mesh.materials[0].alpha_cutoff, 0.5);
    assert!(!mesh.materials[0].double_sided);
    assert_eq!(mesh.materials[1].alpha_mode, MaterialAlphaMode::Mask);
    assert_eq!(mesh.materials[1].alpha_cutoff, 0.3);
    assert!(mesh.materials[1].double_sided);
    assert_eq!(mesh.materials[2].alpha_mode, MaterialAlphaMode::Blend);
    assert_eq!(mesh.materials[2].base_color_factor.w, 0.25);
    assert_eq!(mesh.submeshes[0].material_index, 1);
    let _ = std::fs::remove_dir_all(&root);
}

// Loads an external-buffer glTF mesh and applies node translation.
#[test]
fn loads_external_buffer_mesh() {
    let root = temp_dir("external");
    let path = write_triangle(
        &root,
        "triangle",
        r#"{ "mesh": 0, "translation": [1, 2, 3] }"#,
    );
    let mesh = GLTFImporter::load(&path.to_string_lossy()).unwrap();
    assert_eq!(mesh.name, "triangle.gltf");
    assert_eq!(mesh.index_count(), 3);
    assert_eq!(mesh.vertices.len(), MeshAsset::VERTEX_FLOAT_COUNT * 3);
    assert_eq!(mesh.local_bounds().0, Float3::new(1.0, 2.0, 3.0));
    assert_eq!(mesh.local_bounds().1, Float3::new(2.0, 3.0, 3.0));
    assert_eq!(mesh.vertices[MeshAsset::UV_FLOAT_OFFSET], 0.0);
    assert_eq!(mesh.vertices[MeshAsset::TANGENT_FLOAT_OFFSET], 1.0);
    assert_eq!(mesh.vertices[MeshAsset::MATERIAL_INDEX_FLOAT_OFFSET], 0.0);
    assert_eq!(mesh.vertices[MeshAsset::WEIGHTS_FLOAT_OFFSET], 1.0);
    assert_eq!(mesh.indices, vec![0, 1, 2]);
    let _ = std::fs::remove_dir_all(&root);
}

// Loads every character vertex attribute for the stylized mesh pipeline.
#[test]
fn loads_character_vertex_attributes() {
    let root = temp_dir("character");
    let mut buffer: Vec<u8> = Vec::new();
    push_f32(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0], &mut buffer);
    push_f32(&[0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0], &mut buffer);
    push_f32(&[0.0, 0.0, 1.0, 0.0, 0.0, 1.0], &mut buffer);
    push_f32(
        &[1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0],
        &mut buffer,
    );
    push_u16(&[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], &mut buffer);
    push_f32(
        &[0.4, 0.3, 0.2, 0.1, 1.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.0, 0.0],
        &mut buffer,
    );
    push_f32(
        &[
            1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0,
            0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 2.0, 0.0, 0.0, 1.0,
        ],
        &mut buffer,
    );
    push_u16(&[0, 1, 2], &mut buffer);
    std::fs::write(root.join("character.bin"), &buffer).unwrap();

    let json = r#"{
  "asset": { "version": "2.0" },
  "buffers": [ { "uri": "character.bin", "byteLength": 350 } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 72, "byteLength": 24 },
    { "buffer": 0, "byteOffset": 96, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 144, "byteLength": 24 },
    { "buffer": 0, "byteOffset": 168, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 216, "byteLength": 128 },
    { "buffer": 0, "byteOffset": 344, "byteLength": 6 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2" },
    { "bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 4, "componentType": 5123, "count": 3, "type": "VEC4" },
    { "bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 6, "componentType": 5126, "count": 2, "type": "MAT4" },
    { "bufferView": 7, "componentType": 5123, "count": 3, "type": "SCALAR" }
  ],
  "images": [
    { "uri": "hero_base.png", "mimeType": "image/png" },
    { "uri": "hero_normal.png", "mimeType": "image/png" }
  ],
  "textures": [ { "source": 0 }, { "source": 1 } ],
  "materials": [
    { "name": "unused", "pbrMetallicRoughness": { "baseColorFactor": [1, 1, 1, 1] } },
    {
      "name": "ink hero",
      "pbrMetallicRoughness": {
        "baseColorFactor": [0.8, 0.7, 0.6, 1],
        "baseColorTexture": { "index": 0 },
        "metallicFactor": 0,
        "roughnessFactor": 0.95
      },
      "normalTexture": { "index": 1 }
    }
  ],
  "meshes": [
    {
      "primitives": [
        {
          "attributes": {
            "POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2,
            "TANGENT": 3, "JOINTS_0": 4, "WEIGHTS_0": 5
          },
          "indices": 7,
          "material": 1
        }
      ]
    }
  ],
  "nodes": [
    { "name": "hero", "mesh": 0, "skin": 0 },
    { "name": "root" },
    { "name": "weapon" }
  ],
  "skins": [ { "name": "hero rig", "joints": [1, 2], "inverseBindMatrices": 6 } ],
  "scenes": [ { "nodes": [0] } ],
  "scene": 0
}"#;
    std::fs::write(root.join("character.gltf"), json).unwrap();
    let mesh = GLTFImporter::load(&root.join("character.gltf").to_string_lossy()).unwrap();

    assert_eq!(mesh.vertices.len(), MeshAsset::VERTEX_FLOAT_COUNT * 3);
    assert_eq!(mesh.vertices[MeshAsset::UV_FLOAT_OFFSET], 0.0);
    assert_eq!(mesh.vertices[MeshAsset::UV_FLOAT_OFFSET + 1], 0.0);
    assert_eq!(mesh.vertices[MeshAsset::TANGENT_FLOAT_OFFSET], 1.0);
    assert_eq!(mesh.vertices[MeshAsset::TANGENT_FLOAT_OFFSET + 3], 1.0);
    assert_eq!(mesh.vertices[MeshAsset::MATERIAL_INDEX_FLOAT_OFFSET], 1.0);
    assert_eq!(mesh.vertices[MeshAsset::JOINTS_FLOAT_OFFSET], 0.0);
    assert_eq!(mesh.vertices[MeshAsset::JOINTS_FLOAT_OFFSET + 3], 3.0);
    assert_eq!(mesh.vertices[MeshAsset::WEIGHTS_FLOAT_OFFSET], 0.4);
    assert_eq!(mesh.vertices[MeshAsset::WEIGHTS_FLOAT_OFFSET + 3], 0.1);

    assert_eq!(
        mesh.textures
            .iter()
            .map(|texture| texture.source_uri.clone())
            .collect::<Vec<_>>(),
        vec![
            Some("hero_base.png".to_string()),
            Some("hero_normal.png".to_string())
        ]
    );
    assert_eq!(mesh.materials.len(), 2);
    assert_eq!(mesh.materials[1].name.as_deref(), Some("ink hero"));
    assert_eq!(
        mesh.materials[1].base_color_factor,
        diffuse_math::simd::simd_compat::Float4::new(0.8, 0.7, 0.6, 1.0)
    );
    assert_eq!(mesh.materials[1].base_color_texture_index, Some(0));
    assert_eq!(mesh.materials[1].normal_texture_index, Some(1));
    assert_eq!(mesh.materials[1].metallic_factor, 0.0);
    assert_eq!(mesh.materials[1].roughness_factor, 0.95);

    assert_eq!(mesh.skins.len(), 1);
    assert_eq!(mesh.skins[0].name.as_deref(), Some("hero rig"));
    assert_eq!(mesh.skins[0].joint_node_indices, vec![1, 2]);
    assert_eq!(mesh.skins[0].inverse_bind_matrices.len(), 2);
    assert_eq!(mesh.skins[0].inverse_bind_matrices[1].columns[3].x, 2.0);
    let _ = std::fs::remove_dir_all(&root);
}

// Loads glTF animation channels and sampler keyframes.
#[test]
fn loads_animation_channels() {
    let root = temp_dir("animation");
    let mut buffer: Vec<u8> = Vec::new();
    push_f32(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0], &mut buffer);
    push_f32(&[0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0], &mut buffer);
    push_f32(&[0.0, 1.0], &mut buffer);
    push_f32(&[0.0, 0.0, 0.0, 1.0, 2.0, 3.0], &mut buffer);
    push_u16(&[0, 1, 2], &mut buffer);
    std::fs::write(root.join("animated.bin"), &buffer).unwrap();

    let json = r#"{
  "asset": { "version": "2.0" },
  "buffers": [ { "uri": "animated.bin", "byteLength": 110 } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 72, "byteLength": 8 },
    { "buffer": 0, "byteOffset": 80, "byteLength": 24 },
    { "buffer": 0, "byteOffset": 104, "byteLength": 6 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR" },
    { "bufferView": 3, "componentType": 5126, "count": 2, "type": "VEC3" },
    { "bufferView": 4, "componentType": 5123, "count": 3, "type": "SCALAR" }
  ],
  "meshes": [ { "primitives": [ { "attributes": { "POSITION": 0, "NORMAL": 1 }, "indices": 4 } ] } ],
  "nodes": [ { "name": "animated", "mesh": 0 } ],
  "animations": [
    {
      "name": "idle",
      "samplers": [ { "input": 2, "output": 3, "interpolation": "STEP" } ],
      "channels": [ { "sampler": 0, "target": { "node": 0, "path": "translation" } } ]
    }
  ],
  "scenes": [ { "nodes": [0] } ],
  "scene": 0
}"#;
    std::fs::write(root.join("animated.gltf"), json).unwrap();
    let mesh = GLTFImporter::load(&root.join("animated.gltf").to_string_lossy()).unwrap();

    assert_eq!(mesh.animations.len(), 1);
    assert_eq!(mesh.animations[0].name.as_deref(), Some("idle"));
    assert_eq!(mesh.animations[0].samplers[0].input_times, vec![0.0, 1.0]);
    assert_eq!(
        mesh.animations[0].samplers[0].output_values[1],
        diffuse_math::simd::simd_compat::Float4::new(1.0, 2.0, 3.0, 0.0)
    );
    assert_eq!(
        mesh.animations[0].samplers[0].interpolation,
        diffuse_assets::asset_pipeline::MeshAnimationInterpolation::Step
    );
    assert_eq!(mesh.animations[0].channels[0].target_node_index, Some(0));
    assert_eq!(
        mesh.animations[0].channels[0].path,
        diffuse_assets::asset_pipeline::MeshAnimationPath::Translation
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Loads glTF buffer-view image data into mesh textures.
#[test]
fn loads_buffer_view_image_texture() {
    let root = temp_dir("buffer-image");
    let mut buffer: Vec<u8> = Vec::new();
    push_f32(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0], &mut buffer);
    push_f32(&[0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0], &mut buffer);
    push_u16(&[0, 1, 2], &mut buffer);
    let image_offset = buffer.len();
    let image = super::portable_png::encode(&[44, 55, 66, 255], 1, 1);
    buffer.extend_from_slice(&image);
    std::fs::write(root.join("buffer-image.bin"), &buffer).unwrap();

    let json = format!(
        r#"{{
  "asset": {{ "version": "2.0" }},
  "buffers": [ {{ "uri": "buffer-image.bin", "byteLength": {} }} ],
  "bufferViews": [
    {{ "buffer": 0, "byteOffset": 0, "byteLength": 36 }},
    {{ "buffer": 0, "byteOffset": 36, "byteLength": 36 }},
    {{ "buffer": 0, "byteOffset": 72, "byteLength": 6 }},
    {{ "buffer": 0, "byteOffset": {}, "byteLength": {} }}
  ],
  "accessors": [
    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
    {{ "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" }},
    {{ "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }}
  ],
  "images": [ {{ "bufferView": 3, "mimeType": "image/png", "name": "embedded" }} ],
  "textures": [ {{ "source": 0 }} ],
  "materials": [ {{ "pbrMetallicRoughness": {{ "baseColorTexture": {{ "index": 0 }} }} }} ],
  "meshes": [ {{ "primitives": [ {{ "attributes": {{ "POSITION": 0, "NORMAL": 1 }}, "indices": 2, "material": 0 }} ] }} ],
  "nodes": [ {{ "mesh": 0 }} ],
  "scenes": [ {{ "nodes": [0] }} ],
  "scene": 0
}}"#,
        buffer.len(),
        image_offset,
        image.len()
    );
    std::fs::write(root.join("buffer-image.gltf"), json).unwrap();

    let mesh = GLTFImporter::load(&root.join("buffer-image.gltf").to_string_lossy()).unwrap();
    let resolved = MeshTextureResolver::decode(&mesh.textures[0], None).unwrap();
    assert_eq!(mesh.textures[0].name.as_deref(), Some("embedded"));
    assert_eq!(mesh.textures[0].data.as_deref(), Some(image.as_slice()));
    assert_eq!(resolved.texture.pixels, vec![44, 55, 66, 255]);
    let _ = std::fs::remove_dir_all(&root);
}

// A missing file reports Swift's `fileNotFound` message.
#[test]
fn missing_file() {
    let error = GLTFImporter::load("/nonexistent/missing.gltf").unwrap_err();
    assert_eq!(
        error.to_string(),
        "gltf file not found: /nonexistent/missing.gltf"
    );
}

// A document without a scene graph reports `missingSceneGraph`.
#[test]
fn missing_scene_graph() {
    let root = temp_dir("missing-graph");
    let json = r#"{"asset":{"version":"2.0"},"buffers":[],"accessors":[]}"#;
    std::fs::write(root.join("empty.gltf"), json).unwrap();
    let error = GLTFImporter::load(&root.join("empty.gltf").to_string_lossy()).unwrap_err();
    assert_eq!(error.to_string(), "missing scene graph");
    let _ = std::fs::remove_dir_all(&root);
}

// The shared-vertex-pool loader deduplicates coincident positions.
#[test]
fn shared_vertex_pool() {
    let root = temp_dir("shared-pool");
    let mut buffer: Vec<u8> = Vec::new();
    push_f32(
        &[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0],
        &mut buffer,
    );
    push_u16(&[0, 1, 2, 3, 1, 2], &mut buffer);
    std::fs::write(root.join("pool.bin"), &buffer).unwrap();
    let json = r#"{
  "asset": { "version": "2.0" },
  "buffers": [ { "uri": "pool.bin", "byteLength": 62 } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 48, "byteLength": 12 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3" },
    { "bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR" }
  ],
  "meshes": [ { "primitives": [ { "attributes": { "POSITION": 0 }, "indices": 1 } ] } ],
  "nodes": [ { "mesh": 0 } ],
  "scenes": [ { "nodes": [0] } ],
  "scene": 0
}"#;
    std::fs::write(root.join("pool.gltf"), json).unwrap();
    let (positions, primitives) =
        GLTFImporter::load_with_shared_vertex_pool(&root.join("pool.gltf").to_string_lossy())
            .unwrap();
    // The fourth position repeats the first, so the pool keeps three entries.
    assert_eq!(positions.len(), 3);
    assert_eq!(primitives.len(), 1);
    assert_eq!(primitives[0].triangle_indices, vec![0, 1, 2, 0, 1, 2]);
    assert!(primitives[0].index_remap.is_some());
    let _ = std::fs::remove_dir_all(&root);
}

// A texture with no source URI reports Swift's `missingSourceURI`.
#[test]
fn texture_without_source_uri() {
    let texture = MeshTexture {
        name: Some("unnamed".to_string()),
        ..Default::default()
    };
    let error = MeshTextureResolver::resolve_path(&texture, Some("/tmp")).unwrap_err();
    assert_eq!(error.to_string(), "texture source uri is missing");
}
