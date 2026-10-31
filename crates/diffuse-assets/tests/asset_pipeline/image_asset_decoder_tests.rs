//! Ported from `Engine/Tests/AssetPipelineTests/ImageAssetDecoderTests.swift`.

use diffuse_assets::asset_pipeline::MeshTexture;
use diffuse_assets::import::image_asset_decoder::{
    DecodedTextureAsset, ImageAssetDecoder, ImageAssetDecoderError,
};
use diffuse_assets::import::mesh_texture_resolver::{
    MeshTextureResolver, MeshTextureResolverError,
};
use std::path::PathBuf;

fn temp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let root = std::env::temp_dir().join(format!("image-decoder-{tag}-{nanos}"));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn png(pixels: &[u8], width: usize, height: usize) -> Vec<u8> {
    super::portable_png::encode(pixels, width, height)
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

// Decodes a PNG file into RGBA8 pixels.
#[test]
fn decodes_png() {
    let root = temp_dir("png");
    let path = root.join("texture.png");
    std::fs::write(&path, png(&[255, 0, 0, 255, 0, 255, 0, 255], 2, 1)).unwrap();
    let decoded = ImageAssetDecoder::decode_rgba8_path(&path.to_string_lossy()).unwrap();
    assert_eq!(decoded.width, 2);
    assert_eq!(decoded.height, 1);
    assert_eq!(decoded.pixels, vec![255, 0, 0, 255, 0, 255, 0, 255]);
    let _ = std::fs::remove_dir_all(&root);
}

// Decodes an in-memory PNG into RGBA8 pixels.
#[test]
fn decodes_in_memory_png() {
    let data = png(&[2, 4, 6, 255, 8, 10, 12, 255], 2, 1);
    let decoded = ImageAssetDecoder::decode_rgba8_data(&data, "memory.png").unwrap();
    assert_eq!(decoded.width, 2);
    assert_eq!(decoded.height, 1);
    assert_eq!(decoded.pixels, vec![2, 4, 6, 255, 8, 10, 12, 255]);
}

// Resolves and decodes a relative mesh texture URI.
#[test]
fn resolves_relative_mesh_texture_uri() {
    let root = temp_dir("relative");
    let texture_path = root.join("hero_base.png");
    std::fs::write(
        &texture_path,
        png(&[12, 34, 56, 255, 78, 90, 123, 255], 2, 1),
    )
    .unwrap();

    let texture = MeshTexture::new(
        None,
        Some("hero_base.png".to_string()),
        Some("image/png".to_string()),
        None,
    );
    let resolved = MeshTextureResolver::decode(&texture, Some(&root.to_string_lossy())).unwrap();
    // `standardizedFileURL` resolves `.`/`..` lexically and does not follow the
    // macOS `/var` -> `/private/var` symlink, so compare against the source path.
    assert_eq!(resolved.path, texture_path.to_string_lossy());
    assert_eq!(resolved.texture.width, 2);
    assert_eq!(resolved.texture.height, 1);
    assert_eq!(
        resolved.texture.pixels,
        vec![12, 34, 56, 255, 78, 90, 123, 255]
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Decodes percent-escaped and backslash mesh texture paths.
#[test]
fn resolves_portable_mesh_texture_uri() {
    let root = temp_dir("portable");
    let textures = root.join("textures");
    std::fs::create_dir_all(&textures).unwrap();
    let texture_path = textures.join("hero base.png");
    std::fs::write(&texture_path, png(&[7, 8, 9, 255], 1, 1)).unwrap();

    let texture = MeshTexture::new(
        None,
        Some("textures\\hero%20base.png".to_string()),
        Some("image/png".to_string()),
        None,
    );
    let resolved = MeshTextureResolver::decode(&texture, Some(&root.to_string_lossy())).unwrap();
    // `standardizedFileURL` resolves `.`/`..` lexically and does not follow the
    // macOS `/var` -> `/private/var` symlink, so compare against the source path.
    assert_eq!(resolved.path, texture_path.to_string_lossy());
    assert_eq!(resolved.texture.pixels, vec![7, 8, 9, 255]);
    let _ = std::fs::remove_dir_all(&root);
}

// Rejects an embedded mesh texture URI at `resolve_path`, as Swift does.
#[test]
fn rejects_embedded_mesh_texture_uri() {
    let texture = MeshTexture::new(
        None,
        Some("data:image/png;base64,AAAA".to_string()),
        Some("image/png".to_string()),
        None,
    );
    assert_eq!(
        MeshTextureResolver::resolve_path(&texture, Some("/tmp")).unwrap_err(),
        MeshTextureResolverError::UnsupportedEmbeddedUri("data:image/png;base64,AAAA".to_string())
    );
}

// Decodes a base64 data URI mesh texture.
#[test]
fn decodes_base64_data_uri_texture() {
    let data = png(&[21, 22, 23, 255], 1, 1);
    let uri = format!("data:image/png;base64,{}", base64(&data));
    let texture = MeshTexture::new(None, Some(uri.clone()), Some("image/png".to_string()), None);
    let resolved = MeshTextureResolver::decode(&texture, None).unwrap();
    assert_eq!(resolved.path, uri);
    assert_eq!(resolved.texture.width, 1);
    assert_eq!(resolved.texture.height, 1);
    assert_eq!(resolved.texture.pixels, vec![21, 22, 23, 255]);
}

// Decodes embedded mesh texture bytes and labels them by name when no URI exists.
#[test]
fn decodes_embedded_texture_data() {
    let data = png(&[31, 32, 33, 255], 1, 1);
    let texture = MeshTexture {
        name: Some("embedded-base".to_string()),
        mime_type: Some("image/png".to_string()),
        data: Some(data),
        ..Default::default()
    };
    let resolved = MeshTextureResolver::decode(&texture, None).unwrap();
    assert_eq!(resolved.path, "embedded-base");
    assert_eq!(resolved.texture.pixels, vec![31, 32, 33, 255]);
}

// An unreadable file reports Swift's `sourceUnreadable` message.
#[test]
fn unreadable_source() {
    let error = ImageAssetDecoder::decode_rgba8_path("/nonexistent/missing.png").unwrap_err();
    assert_eq!(
        error,
        ImageAssetDecoderError::SourceUnreadable("/nonexistent/missing.png".to_string())
    );
    assert_eq!(
        error.to_string(),
        "image source unreadable: /nonexistent/missing.png"
    );
}

// Empty bytes are rejected before the bridge is called.
#[test]
fn empty_data_is_rejected() {
    let error = ImageAssetDecoder::decode_rgba8_data(&[], "empty").unwrap_err();
    assert_eq!(
        error,
        ImageAssetDecoderError::SourceUnreadable("empty".to_string())
    );
}

// A relative URI without a source directory reports Swift's message.
#[test]
fn relative_uri_without_directory() {
    let texture = MeshTexture::new(None, Some("hero.png".to_string()), None, None);
    assert_eq!(
        MeshTextureResolver::resolve_path(&texture, None).unwrap_err(),
        MeshTextureResolverError::RelativeUriWithoutSourceDirectory("hero.png".to_string())
    );
    assert_eq!(
        MeshTextureResolver::resolve_path(&texture, Some("")).unwrap_err(),
        MeshTextureResolverError::RelativeUriWithoutSourceDirectory("hero.png".to_string())
    );
}

// A non-`file` scheme is rejected, and absolute paths resolve without a directory.
#[test]
fn absolute_and_unsupported_uris() {
    let absolute = MeshTexture::new(None, Some("/tmp/hero.png".to_string()), None, None);
    assert_eq!(
        MeshTextureResolver::resolve_path(&absolute, None).unwrap(),
        "/tmp/hero.png"
    );
    let remote = MeshTexture::new(
        None,
        Some("https://example.com/hero.png".to_string()),
        None,
        None,
    );
    assert_eq!(
        MeshTextureResolver::resolve_path(&remote, None).unwrap_err(),
        MeshTextureResolverError::UnsupportedUri("https://example.com/hero.png".to_string())
    );
    let file = MeshTexture::new(None, Some("file:///tmp/hero.png".to_string()), None, None);
    assert_eq!(
        MeshTextureResolver::resolve_path(&file, None).unwrap(),
        "/tmp/hero.png"
    );
}

// `DecodedTextureAsset` keeps straight-alpha RGBA8 lanes in order.
#[test]
fn decoded_texture_asset_shape() {
    let asset = DecodedTextureAsset::new(vec![1, 2, 3, 4], 1, 1);
    assert_eq!(asset.pixels, vec![1, 2, 3, 4]);
    assert_eq!((asset.width, asset.height), (1, 1));
}
