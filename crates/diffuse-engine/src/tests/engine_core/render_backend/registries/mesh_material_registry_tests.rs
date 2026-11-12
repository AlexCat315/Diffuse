//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Registries/MeshMaterialRegistryTests.swift`.

use diffuse_assets::asset_pipeline::{MeshAsset, MeshMaterial, MeshTexture};
use diffuse_math::simd::simd_compat::Float4;
use diffuse_render::registries::mesh_material_registry::MeshMaterialRegistry;
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;

/// Registers mesh material and texture metadata by mesh index.
#[test]
fn registers_material_metadata() {
    MeshMaterialRegistry::clear_all();

    let material = MeshMaterial::new(
        Some("ink".to_string()),
        Float4::new(0.5, 0.4, 0.3, 1.0),
        Some(0),
        None,
        None,
        0.0,
        1.0,
        MaterialAlphaMode::Opaque,
        0.5,
        false,
    );
    let texture = MeshTexture::new(
        None,
        Some("ink.png".to_string()),
        Some("image/png".to_string()),
        None,
    );
    let mut mesh = MeshAsset::new("hero", Vec::new(), Vec::new());
    mesh.materials = vec![material.clone()];
    mesh.textures = vec![texture.clone()];

    MeshMaterialRegistry::register_mesh(7, &mesh);

    let set = MeshMaterialRegistry::materials(7).expect("materials");
    assert_eq!(set.materials, vec![material]);
    assert_eq!(set.textures, vec![texture]);
    assert!(MeshMaterialRegistry::materials(8).is_none());

    MeshMaterialRegistry::clear_all();
}
