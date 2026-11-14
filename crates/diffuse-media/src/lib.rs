//! Crate root. See MIGRATION.md §5.
//!
//! Diffuse owns the editing/timeline/export strategy. Generic demux and decode
//! come from `cove-media` (FFmpeg 9.x built into `OUT_DIR`); the pinned FFmpeg
//! 8.1.3 artifact bundle and its `CFFmpegBridge` C sources were removed in
//! batch 85; reader and bounded resident-clip APIs use Cove's decoder.

pub mod decoding;
pub mod editing;

#[cfg(test)]
mod tests;

pub use decoding::values::{MediaAsset, MediaAssetVideo, MediaError, MediaUrl};
pub use decoding::readers::{AudioFile, AudioReader, VideoReader};
