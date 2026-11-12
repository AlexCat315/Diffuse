//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Registries/MeshTextureRegistryTests.swift`.

use std::path::PathBuf;

use diffuse_assets::asset_pipeline::{MeshAsset, MeshTexture};
use diffuse_render::registries::mesh_texture_registry::MeshTextureRegistry;

use crate::tests::engine_core::portable_png;

fn temporary_root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "diffuse-mesh-texture-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("create temporary root");
    root
}

/// Decodes mesh textures into the render texture cache.
#[test]
fn decodes_mesh_textures() {
    MeshTextureRegistry::clear_all();
    let root = temporary_root();
    let texture_path = root.join("hero_ink.png");
    std::fs::write(
        &texture_path,
        portable_png::encode(&[21, 22, 23, 255, 31, 32, 33, 255], 2, 1),
    )
    .expect("write png");

    let mut mesh = MeshAsset::new("hero", Vec::new(), Vec::new());
    mesh.textures = vec![MeshTexture::new(
        None,
        Some("hero_ink.png".to_string()),
        Some("image/png".to_string()),
        None,
    )];

    let report = MeshTextureRegistry::register(12, &mesh, Some(&root.to_string_lossy()));

    assert!(report.failures.is_empty());
    assert_eq!(
        report
            .decoded_textures
            .iter()
            .map(|texture| texture.texture_index)
            .collect::<Vec<_>>(),
        vec![0]
    );
    assert_eq!(
        report.decoded_textures[0].source_path,
        format!("{}/hero_ink.png", root.to_string_lossy())
    );
    assert_eq!(
        report.decoded_textures[0].texture.pixels,
        vec![21, 22, 23, 255, 31, 32, 33, 255]
    );
    assert_eq!(MeshTextureRegistry::textures(12), Some(report));

    MeshTextureRegistry::clear_all();
    let _ = std::fs::remove_dir_all(&root);
}

/// Records mesh texture decode failures without dropping the report.
#[test]
fn records_decode_failures() {
    MeshTextureRegistry::clear_all();

    let mut mesh = MeshAsset::new("hero", Vec::new(), Vec::new());
    mesh.textures = vec![MeshTexture::new(
        None,
        Some("missing.png".to_string()),
        Some("image/png".to_string()),
        None,
    )];

    let report = MeshTextureRegistry::register(13, &mesh, None);

    assert!(report.decoded_textures.is_empty());
    assert_eq!(report.failures.len(), 1);
    assert_eq!(report.failures[0].texture_index, 0);
    assert_eq!(
        report.failures[0].source_uri.as_deref(),
        Some("missing.png")
    );
    assert_eq!(MeshTextureRegistry::textures(13), Some(report));

    MeshTextureRegistry::clear_all();
}
