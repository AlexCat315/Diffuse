//! OpenEXR reading through the `COpenEXRBridge` C++ bridge.
//!
//! The reader owns one opaque context. The bridge hands back `char*` pointers
//! into the context's own storage for layer descriptors; they are copied into
//! Rust strings immediately, before any other bridge call can invalidate them.

use core::ffi::{CStr, c_char, c_float, c_int};
use std::ffi::CString;

/// `typedef struct CoveEXRContextImpl* CoveEXRContext`.
#[repr(C)]
pub struct CoveEXRContextImpl {
    _private: [u8; 0],
}

pub type CoveEXRContext = *mut CoveEXRContextImpl;

/// `typedef enum CoveEXRPixelType { COVE_EXR_UINT = 0, COVE_EXR_HALF = 1,
/// COVE_EXR_FLOAT = 2 }`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CoveEXRPixelType {
    Uint = 0,
    Half = 1,
    Float = 2,
}

/// `typedef struct CoveEXRLayerDesc { const char* name; const char* channels;
/// int32_t channel_count; }`.
///
/// The C struct is two pointers and an `int32_t`: 24 bytes, 8-aligned on 64-bit
/// targets. The assertions below keep the ABI honest.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CoveEXRLayerDesc {
    pub name: *const c_char,
    pub channels: *const c_char,
    pub channel_count: i32,
}

const _: () = assert!(core::mem::size_of::<CoveEXRLayerDesc>() == 24);
const _: () = assert!(core::mem::align_of::<CoveEXRLayerDesc>() == 8);
const _: () = assert!(core::mem::size_of::<c_int>() == 4);
const _: () = assert!(core::mem::size_of::<c_float>() == 4);
const _: () = assert!(core::mem::size_of::<CoveEXRPixelType>() == 4);

unsafe extern "C" {
    // Reader.
    fn cove_exr_reader_open(path: *const c_char) -> CoveEXRContext;
    fn cove_exr_reader_close(ctx: CoveEXRContext);
    fn cove_exr_reader_get_width(ctx: CoveEXRContext) -> i32;
    fn cove_exr_reader_get_height(ctx: CoveEXRContext) -> i32;
    fn cove_exr_reader_get_layer_count(ctx: CoveEXRContext) -> i32;
    fn cove_exr_reader_get_layer_desc(
        ctx: CoveEXRContext,
        index: i32,
        out_desc: *mut CoveEXRLayerDesc,
    ) -> bool;
    fn cove_exr_reader_read_layer_pixels(
        ctx: CoveEXRContext,
        layer_name: *const c_char,
        out_pixels: *mut c_float,
        pixel_count: i32,
    ) -> bool;
}

/// `public enum EXRReaderError: Error { case openFailed(String) }`.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EXRReaderError {
    /// `case openFailed(String)`
    #[error("Failed to open EXR file: {0}")]
    OpenFailed(String),
}

/// `public final class EXRReader: @unchecked Sendable`.
pub struct EXRReader {
    context: Option<CoveEXRContext>,
    pub path: String,
}

// SAFETY: the context is an owned, opaque C++ object with no thread affinity of
// its own; the Swift class was `@unchecked Sendable` for the same reason. Moving
// the reader between threads is sound because `EXRReader` is the only owner, and
// the bridge keeps no shared globals.
unsafe impl Send for EXRReader {}

/// `public struct LayerInfo: Sendable { let name: String; let channels: [String] }`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LayerInfo {
    pub name: String,
    pub channels: Vec<String>,
}

impl EXRReader {
    /// `public init(path: String) throws`.
    pub fn new(path: impl Into<String>) -> Result<Self, EXRReaderError> {
        let path = path.into();
        let c_path = CString::new(path.as_str()).map_err(|_| {
            // A path with an interior NUL can never name a file, so the bridge
            // would report the same `openFailed`.
            EXRReaderError::OpenFailed(path.clone())
        })?;
        // SAFETY: `c_path` is a live NUL-terminated string; the bridge either
        // returns null or a context this struct becomes the sole owner of.
        let context = unsafe { cove_exr_reader_open(c_path.as_ptr()) };
        if context.is_null() {
            return Err(EXRReaderError::OpenFailed(path));
        }
        Ok(EXRReader {
            context: Some(context),
            path,
        })
    }

    /// `public var width: Int` — 0 when there is no context.
    pub fn width(&self) -> usize {
        match self.context {
            // SAFETY: the context pointer is non-null and owned by `self`, which
            // outlives this call.
            Some(ctx) => unsafe { cove_exr_reader_get_width(ctx).max(0) as usize },
            None => 0,
        }
    }

    /// `public var height: Int` — 0 when there is no context.
    pub fn height(&self) -> usize {
        match self.context {
            // SAFETY: as in `width`.
            Some(ctx) => unsafe { cove_exr_reader_get_height(ctx).max(0) as usize },
            None => 0,
        }
    }

    /// `public var layerCount: Int` — 0 when there is no context.
    pub fn layer_count(&self) -> usize {
        match self.context {
            // SAFETY: as in `width`.
            Some(ctx) => unsafe { cove_exr_reader_get_layer_count(ctx).max(0) as usize },
            None => 0,
        }
    }

    /// `public func layerInfo(at index: Int) -> LayerInfo?`.
    ///
    /// The bridge points into its own layer storage, so both strings are copied
    /// before returning; the C++ side explicitly warns that the pointers dangle
    /// once the context is destroyed or the call is repeated.
    pub fn layer_info(&self, index: usize) -> Option<LayerInfo> {
        let ctx = self.context?;
        // Swift passes `Int32(index)`; a value that does not fit is out of range
        // for any real file, which the bridge also rejects.
        let index = i32::try_from(index).ok()?;
        let mut desc = CoveEXRLayerDesc {
            name: core::ptr::null(),
            channels: core::ptr::null(),
            channel_count: 0,
        };
        // SAFETY: the context is live and `desc` is a writable, correctly laid
        // out `CoveEXRLayerDesc`. The bridge fills the pointers with strings it
        // owns; they are copied immediately below.
        let ok = unsafe { cove_exr_reader_get_layer_desc(ctx, index, &mut desc) };
        if !ok {
            return None;
        }
        let name = if desc.name.is_null() {
            String::new()
        } else {
            // SAFETY: non-null means the bridge wrote a NUL-terminated string it
            // owns; it stays valid until the next bridge call.
            unsafe { CStr::from_ptr(desc.name) }
                .to_string_lossy()
                .into_owned()
        };
        let channels = if desc.channels.is_null() {
            Vec::new()
        } else {
            // SAFETY: as above. Swift splits the comma-joined list with
            // `components(separatedBy: ",")`, which keeps empty components for
            // an empty list ("".components → [""]); the bridge never writes an
            // empty string, and a null pointer maps to no channels.
            unsafe { CStr::from_ptr(desc.channels) }
                .to_string_lossy()
                .split(',')
                .map(|channel| channel.to_string())
                .collect()
        };
        let _ = desc.channel_count;
        Some(LayerInfo { name, channels })
    }

    /// `public func readPixels(layerName: String) -> [Float]`.
    ///
    /// Returns `[]` when the layer is missing or the read fails, matching the
    /// Swift `return []` paths. The requested length is `width * height * 4`,
    /// i.e. RGBA regardless of the layer's channel count.
    pub fn read_pixels(&self, layer_name: &str) -> Vec<f32> {
        let Some(ctx) = self.context else {
            return Vec::new();
        };
        let pixel_count = self.width() * self.height() * 4;
        let mut pixels = vec![0.0_f32; pixel_count];
        let Ok(name) = CString::new(layer_name) else {
            return Vec::new();
        };
        // SAFETY: the context is live, `name` is a NUL-terminated string, and
        // `pixels` is a writable buffer of exactly `pixel_count` floats, which is
        // the count reported to the bridge.
        let ok = unsafe {
            cove_exr_reader_read_layer_pixels(
                ctx,
                name.as_ptr(),
                pixels.as_mut_ptr(),
                i32::try_from(pixel_count).unwrap_or(i32::MAX),
            )
        };
        if !ok {
            return Vec::new();
        }
        pixels
    }
}

impl Drop for EXRReader {
    fn drop(&mut self) {
        if let Some(ctx) = self.context.take() {
            // SAFETY: `ctx` came from `cove_exr_reader_open` and is closed exactly
            // once, here, because `EXRReader` is the sole owner.
            unsafe { cove_exr_reader_close(ctx) };
        }
    }
}
