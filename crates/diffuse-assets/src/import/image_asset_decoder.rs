//! RGBA8 image decoding through Cove's native image bridge.
//!
//! Ported from `Engine/Sources/AssetPipeline/Import/ImageAssetDecoder.swift`.
//!
//! The Swift file called `cove_image_decode_memory` from
//! `CImageDecodeBridge`; the Rust workspace uses `cove_imaging::ImageDecoder`,
//! which wraps the same native bridge (stb_image for png/jpg/bmp/gif/tga,
//! libwebp for webp, lunasvg for svg). One code path on every platform — no
//! Apple ImageIO special case.

use cove_imaging::{ImageDecodeError, ImageDecoder};

/// Straight-alpha RGBA8 pixels.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodedTextureAsset {
    pub pixels: Vec<u8>,
    pub width: usize,
    pub height: usize,
}

impl DecodedTextureAsset {
    pub fn new(pixels: Vec<u8>, width: usize, height: usize) -> Self {
        DecodedTextureAsset {
            pixels,
            width,
            height,
        }
    }
}

/// Every decode failure, matching Swift's `ImageAssetDecoderError` cases.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ImageAssetDecoderError {
    #[error("image source unreadable: {0}")]
    SourceUnreadable(String),
    #[error("image missing first frame: {0}")]
    ImageMissing(String),
    #[error("image has invalid dimensions: {0}")]
    InvalidDimensions(String),
    #[error("image decode failed: {0}")]
    DecodeFailed(String),
}

pub struct ImageAssetDecoder;

impl ImageAssetDecoder {
    pub fn decode_rgba8_path(path: &str) -> Result<DecodedTextureAsset, ImageAssetDecoderError> {
        let data = std::fs::read(path)
            .map_err(|_| ImageAssetDecoderError::SourceUnreadable(path.to_string()))?;
        let extension = std::path::Path::new(path)
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        ImageAssetDecoder::decode(&data, extension, path)
    }

    /// The extension is unknown for raw bytes; the bridge sniffs the format.
    pub fn decode_rgba8_data(
        data: &[u8],
        label: &str,
    ) -> Result<DecodedTextureAsset, ImageAssetDecoderError> {
        ImageAssetDecoder::decode(data, "", label)
    }

    fn decode(
        data: &[u8],
        extension: &str,
        label: &str,
    ) -> Result<DecodedTextureAsset, ImageAssetDecoderError> {
        if data.is_empty() {
            return Err(ImageAssetDecoderError::SourceUnreadable(label.to_string()));
        }
        let decoded = ImageDecoder::decode_with_hint(data, extension, None).map_err(|error| {
            let message = match error {
                ImageDecodeError::DecodeFailure(message) => message,
                other => other.to_string(),
            };
            ImageAssetDecoderError::DecodeFailed(format!("{label}: {message}"))
        })?;
        if decoded.width() == 0 || decoded.height() == 0 {
            return Err(ImageAssetDecoderError::InvalidDimensions(label.to_string()));
        }
        let width = decoded.width() as usize;
        let height = decoded.height() as usize;
        let byte_count = width * height * 4;
        let pixels = decoded.pixels();
        if pixels.len() < byte_count {
            return Err(ImageAssetDecoderError::ImageMissing(label.to_string()));
        }
        Ok(DecodedTextureAsset::new(
            pixels[..byte_count].to_vec(),
            width,
            height,
        ))
    }
}
