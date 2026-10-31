//! Crate root. See MIGRATION.md §5.
pub mod decoding;
pub mod editing;

#[cfg(test)]
mod tests;

pub use decoding::decoder::{FileDecoder, GMStreamInfo};
pub use decoding::readers::{AudioFile, AudioReader, VideoReader};
pub use decoding::values::{
    MediaAsset, MediaAssetVideo, MediaError, MediaUrl, PCMBuffer, VideoFrame,
};
