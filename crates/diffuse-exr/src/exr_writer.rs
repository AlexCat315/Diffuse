//! OpenEXR writing through the `COpenEXRBridge` C++ bridge.
//!
//! The writer accumulates layers, then writes all of them in one multi-part
//! file. Channel names are passed to the bridge comma-joined, exactly as the
//! Swift code did, and the bridge records that declaration order so a reader can
//! undo the channel list's alphabetical sorting.

use core::ffi::{c_char, c_float};
use std::ffi::CString;

use crate::exr_reader::{CoveEXRContext, CoveEXRLayerDesc, CoveEXRPixelType};

unsafe extern "C" {
    fn cove_exr_writer_create(path: *const c_char, width: i32, height: i32) -> CoveEXRContext;
    fn cove_exr_writer_destroy(ctx: CoveEXRContext);
    fn cove_exr_writer_add_layer(
        ctx: CoveEXRContext,
        layer: *const CoveEXRLayerDesc,
        pixel_type: CoveEXRPixelType,
    ) -> bool;
    fn cove_exr_writer_set_layer_pixels(
        ctx: CoveEXRContext,
        layer_name: *const c_char,
        pixels: *const c_float,
        pixel_count: i32,
    ) -> bool;
    fn cove_exr_writer_write(ctx: CoveEXRContext) -> bool;
}

/// `public enum PixelType: Sendable { case half; case float }`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PixelType {
    /// `case half`
    #[default]
    Half,
    /// `case float`
    Float,
}

/// `public struct Layer: Sendable`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layer {
    pub name: String,
    pub channels: Vec<String>,
    pub pixel_type: PixelType,
}

impl Layer {
    /// `public init(name:channels:pixelType:)` with the Swift default
    /// `pixelType: .half`.
    pub fn new<I, S>(name: impl Into<String>, channels: I, pixel_type: PixelType) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Layer {
            name: name.into(),
            channels: channels.into_iter().map(Into::into).collect(),
            pixel_type,
        }
    }

    /// `Layer(name:channels:)` — the `pixelType: .half` default argument.
    pub fn with_half<I, S>(name: impl Into<String>, channels: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Layer::new(name, channels, PixelType::Half)
    }
}

/// `public enum EXRWriterError: Error`.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EXRWriterError {
    /// `case contextCreationFailed`
    #[error("Failed to create EXR writer context")]
    ContextCreationFailed,
    /// `case layerCreationFailed(String)`
    #[error("Failed to create EXR layer: {0}")]
    LayerCreationFailed(String),
    /// `case writeFailed(String)`
    #[error("Failed to write EXR file: {0}")]
    WriteFailed(String),
}

/// `public final class EXRWriter: @unchecked Sendable`.
pub struct EXRWriter {
    path: String,
    width: usize,
    height: usize,
    context: Option<CoveEXRContext>,
    layer_names: Vec<String>,
}

// SAFETY: the context is an owned, opaque C++ object with no thread affinity of
// its own (Swift declared the class `@unchecked Sendable` for the same reason).
// `EXRWriter` is the only owner, so moving it between threads is sound.
unsafe impl Send for EXRWriter {}

impl EXRWriter {
    /// `public init(path:width:height:) throws`.
    pub fn new(
        path: impl Into<String>,
        width: usize,
        height: usize,
    ) -> Result<Self, EXRWriterError> {
        let path = path.into();
        let c_path =
            CString::new(path.as_str()).map_err(|_| EXRWriterError::ContextCreationFailed)?;
        // `Int32(width)` / `Int32(height)`: values that do not fit are rejected by
        // the bridge's `width <= 0 || height <= 0` guard, so the saturated value
        // cannot reach it as a positive number unless the original was positive.
        let width_i32 = i32::try_from(width).map_err(|_| EXRWriterError::ContextCreationFailed)?;
        let height_i32 =
            i32::try_from(height).map_err(|_| EXRWriterError::ContextCreationFailed)?;
        // SAFETY: `c_path` is a live NUL-terminated string; the bridge returns
        // null or a context this struct becomes the sole owner of.
        let context = unsafe { cove_exr_writer_create(c_path.as_ptr(), width_i32, height_i32) };
        if context.is_null() {
            return Err(EXRWriterError::ContextCreationFailed);
        }
        Ok(EXRWriter {
            path,
            width,
            height,
            context: Some(context),
            layer_names: Vec::new(),
        })
    }

    /// The path this writer will produce.
    pub fn path(&self) -> &str {
        &self.path
    }

    /// The raster the writer was created with.
    pub fn width(&self) -> usize {
        self.width
    }

    /// The raster the writer was created with.
    pub fn height(&self) -> usize {
        self.height
    }

    /// `public func addLayer(_ layer: Layer)`.
    ///
    /// Failures are silent in Swift — a layer that the bridge rejects is simply
    /// not recorded, so a later `setPixels` for it returns `false`.
    pub fn add_layer(&mut self, layer: &Layer) {
        let Some(ctx) = self.context else {
            return;
        };
        let channel_string = layer.channels.join(",");
        let Ok(name) = CString::new(layer.name.as_str()) else {
            return;
        };
        let Ok(channels) = CString::new(channel_string) else {
            return;
        };
        let desc = CoveEXRLayerDesc {
            name: name.as_ptr(),
            channels: channels.as_ptr(),
            channel_count: i32::try_from(layer.channels.len()).unwrap_or(i32::MAX),
        };
        let pixel_type = match layer.pixel_type {
            PixelType::Float => CoveEXRPixelType::Float,
            PixelType::Half => CoveEXRPixelType::Half,
        };
        // SAFETY: the context is live, `name`/`channels` outlive the call, and
        // `desc` is a correctly laid out descriptor pointing at them. The bridge
        // copies what it needs.
        let added = unsafe { cove_exr_writer_add_layer(ctx, &desc, pixel_type) };
        if added {
            self.layer_names.push(layer.name.clone());
        }
    }

    /// `public func setPixels(_ pixels: [Float], for layerName: String) -> Bool`.
    pub fn set_pixels(&self, pixels: &[f32], layer_name: &str) -> bool {
        let Some(ctx) = self.context else {
            return false;
        };
        let Ok(name) = CString::new(layer_name) else {
            return false;
        };
        // SAFETY: the context is live, `name` is NUL-terminated, and `pixels`
        // exposes exactly `pixels.len()` readable floats, which is the count
        // reported to the bridge.
        unsafe {
            cove_exr_writer_set_layer_pixels(
                ctx,
                name.as_ptr(),
                pixels.as_ptr(),
                i32::try_from(pixels.len()).unwrap_or(i32::MAX),
            )
        }
    }

    /// `public func write() throws`.
    pub fn write(&self) -> Result<(), EXRWriterError> {
        let Some(ctx) = self.context else {
            return Err(EXRWriterError::ContextCreationFailed);
        };
        // SAFETY: the context is live and owned by `self`; the bridge writes the
        // file and reports success as a bool.
        let wrote = unsafe { cove_exr_writer_write(ctx) };
        if !wrote {
            return Err(EXRWriterError::WriteFailed(self.path.clone()));
        }
        Ok(())
    }

    /// Layers the bridge accepted, in insertion order.
    pub fn layer_names(&self) -> &[String] {
        &self.layer_names
    }
}

impl Drop for EXRWriter {
    fn drop(&mut self) {
        if let Some(ctx) = self.context.take() {
            // SAFETY: `ctx` came from `cove_exr_writer_create` and is destroyed
            // exactly once, here, because `EXRWriter` is the sole owner.
            unsafe { cove_exr_writer_destroy(ctx) };
        }
    }
}
