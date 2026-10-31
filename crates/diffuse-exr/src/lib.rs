//! Crate root. See MIGRATION.md §5.
pub mod exr_reader;
pub mod exr_writer;

pub use exr_reader::{EXRReader, EXRReaderError, LayerInfo};
pub use exr_writer::{EXRWriter, EXRWriterError, Layer, PixelType};
