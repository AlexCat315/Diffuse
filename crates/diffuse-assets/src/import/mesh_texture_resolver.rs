//! Texture URI resolution and decoding for imported meshes.
//!
//! Ported from `Engine/Sources/AssetPipeline/Import/MeshTextureResolver.swift`.
//! Foundation's `URL` is replaced by [`diffuse_media::MediaUrl`]
//! (MIGRATION.md §8), not by a second shim.

use diffuse_media::MediaUrl;

use crate::asset_pipeline::MeshTexture;
use crate::import::image_asset_decoder::{DecodedTextureAsset, ImageAssetDecoder};

/// Every resolution failure, matching Swift's `MeshTextureResolverError`.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum MeshTextureResolverError {
    #[error("texture source uri is missing")]
    MissingSourceUri,
    #[error("embedded texture uri is not supported yet: {0}")]
    UnsupportedEmbeddedUri(String),
    #[error("relative texture uri requires a source directory: {0}")]
    RelativeUriWithoutSourceDirectory(String),
    #[error("unsupported texture uri: {0}")]
    UnsupportedUri(String),
}

/// A texture decoded together with the path it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedMeshTexture {
    pub path: String,
    pub texture: DecodedTextureAsset,
}

impl ResolvedMeshTexture {
    pub fn new(path: String, texture: DecodedTextureAsset) -> Self {
        ResolvedMeshTexture { path, texture }
    }
}

pub struct MeshTextureResolver;

impl MeshTextureResolver {
    /// The filesystem path a texture URI resolves to.
    pub fn resolve_path(
        texture: &MeshTexture,
        source_directory: Option<&str>,
    ) -> Result<String, MeshTextureResolverError> {
        let uri = match &texture.source_uri {
            Some(uri) if !uri.is_empty() => uri.clone(),
            _ => return Err(MeshTextureResolverError::MissingSourceUri),
        };
        if uri.starts_with("data:") {
            return Err(MeshTextureResolverError::UnsupportedEmbeddedUri(uri));
        }
        let decoded_uri = percent_decode(&uri)
            .unwrap_or_else(|| uri.clone())
            .replace('\\', "/");
        // Swift's `#if os(Windows)` branch: a drive-letter or UNC path is already
        // absolute even though it has no leading slash.
        #[cfg(target_os = "windows")]
        {
            if decoded_uri.starts_with("//") || is_windows_drive_path(&decoded_uri) {
                return Ok(MediaUrl::from_file_path(&decoded_uri)
                    .standardized_file_url()
                    .path()
                    .to_string());
            }
        }
        if let Some(scheme_end) = uri.find(':') {
            let scheme = &uri[..scheme_end];
            let is_scheme = !scheme.is_empty()
                && scheme
                    .chars()
                    .next()
                    .map(|first| first.is_ascii_alphabetic())
                    .unwrap_or(false)
                && scheme.chars().all(|character| {
                    character.is_ascii_alphanumeric() || "+-.".contains(character)
                });
            if is_scheme {
                if scheme != "file" {
                    return Err(MeshTextureResolverError::UnsupportedUri(uri));
                }
                let parsed = MediaUrl::parse(uri.clone())
                    .ok_or_else(|| MeshTextureResolverError::UnsupportedUri(uri.clone()))?;
                if !parsed.is_file_url() {
                    return Err(MeshTextureResolverError::UnsupportedUri(uri));
                }
                return Ok(parsed.path().to_string());
            }
        }
        if decoded_uri.starts_with('/') {
            return Ok(MediaUrl::from_file_path(&decoded_uri)
                .standardized_file_url()
                .path()
                .to_string());
        }
        let directory = match source_directory {
            Some(directory) if !directory.is_empty() => directory,
            _ => {
                return Err(MeshTextureResolverError::RelativeUriWithoutSourceDirectory(
                    uri,
                ));
            }
        };
        Ok(MediaUrl::from_file_path(directory)
            .appending_path_component(&decoded_uri)
            .standardized_file_url()
            .path()
            .to_string())
    }

    /// Decodes a texture, preferring in-memory bytes and inline data URIs before
    /// falling back to the resolved path.
    pub fn decode(
        texture: &MeshTexture,
        source_directory: Option<&str>,
    ) -> Result<ResolvedMeshTexture, MeshTextureResolverError> {
        if let Some(data) = &texture.data {
            let label = texture
                .source_uri
                .clone()
                .or_else(|| texture.name.clone())
                .unwrap_or_else(|| "<embedded>".to_string());
            let decoded =
                ImageAssetDecoder::decode_rgba8_data(data, &label).map_err(decode_error)?;
            return Ok(ResolvedMeshTexture::new(label, decoded));
        }
        if let Some(uri) = &texture.source_uri
            && uri.starts_with("data:")
        {
            let data = decode_data_uri(uri)?;
            let decoded = ImageAssetDecoder::decode_rgba8_data(&data, uri).map_err(decode_error)?;
            return Ok(ResolvedMeshTexture::new(uri.clone(), decoded));
        }
        let path = MeshTextureResolver::resolve_path(texture, source_directory)?;
        let decoded = ImageAssetDecoder::decode_rgba8_path(&path).map_err(decode_error)?;
        Ok(ResolvedMeshTexture::new(path, decoded))
    }
}

/// Swift's decoder throws its own error type; the resolver forwarded it
/// unchanged, so the two are folded into one variant here.
fn decode_error(
    error: crate::import::image_asset_decoder::ImageAssetDecoderError,
) -> MeshTextureResolverError {
    match error {
        crate::import::image_asset_decoder::ImageAssetDecoderError::SourceUnreadable(_)
        | crate::import::image_asset_decoder::ImageAssetDecoderError::ImageMissing(_)
        | crate::import::image_asset_decoder::ImageAssetDecoderError::InvalidDimensions(_)
        | crate::import::image_asset_decoder::ImageAssetDecoderError::DecodeFailed(_) => {
            MeshTextureResolverError::UnsupportedUri(error.to_string())
        }
    }
}

fn decode_data_uri(uri: &str) -> Result<Vec<u8>, MeshTextureResolverError> {
    let Some(comma) = uri.find(',') else {
        return Err(MeshTextureResolverError::UnsupportedEmbeddedUri(
            uri.to_string(),
        ));
    };
    let metadata = &uri[..comma];
    let payload = &uri[(comma + 1)..];
    if metadata.contains(";base64") {
        return base64_decode(payload)
            .ok_or_else(|| MeshTextureResolverError::UnsupportedEmbeddedUri(uri.to_string()));
    }
    let decoded = percent_decode(payload)
        .ok_or_else(|| MeshTextureResolverError::UnsupportedEmbeddedUri(uri.to_string()))?;
    Ok(decoded.into_bytes())
}

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

/// `decodedURI.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil`.
#[cfg(target_os = "windows")]
fn is_windows_drive_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'/'
}
