//! Synchronous FFmpeg decoding through the C bridge.
//!
//! Swift's `FileDecoder` is an `@unchecked Sendable` class whose one invariant is
//! that a decoder is touched by a single thread at a time ("Kept private to
//! synchronous decoding or a reader actor"). [`FileDecoder`] keeps the same
//! shape: it owns the C handle, closes it on drop, and the readers in
//! `readers.rs` serialize access.

use core::ffi::{c_char, c_float, c_int, c_uchar};
use std::ffi::CString;

use crate::decoding::values::{MediaError, MediaUrl, PCMBuffer, VideoFrame};

/// Opaque demuxer/decoder pair owned by `native/Decoder.c`.
#[repr(C)]
pub struct GMDecoder {
    _private: [u8; 0],
}

/// Mirrors `GMStreamInfo` in `native/include/CFFmpegBridge.h`.
///
/// The C struct is `{ double duration; int width, height; int sample_rate,
/// channels; }`. `int` is 4 bytes with 4-byte alignment on every supported
/// target, so the aggregate is 24 bytes with 8-byte alignment.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GMStreamInfo {
    pub duration: f64,
    pub width: c_int,
    pub height: c_int,
    pub sample_rate: c_int,
    pub channels: c_int,
}

const _: () = assert!(core::mem::size_of::<GMStreamInfo>() == 24);
const _: () = assert!(core::mem::align_of::<GMStreamInfo>() == 8);
const _: () = assert!(core::mem::size_of::<c_int>() == 4);
const _: () = assert!(core::mem::size_of::<c_float>() == 4);

unsafe extern "C" {
    fn gm_open(
        path: *const c_char,
        video: c_int,
        error: *mut c_char,
        capacity: usize,
    ) -> *mut GMDecoder;
    fn gm_close(decoder: *mut GMDecoder);
    fn gm_info(decoder: *const GMDecoder) -> GMStreamInfo;
    fn gm_seek(decoder: *mut GMDecoder, seconds: f64, error: *mut c_char, capacity: usize)
    -> c_int;
    fn gm_read_audio(
        decoder: *mut GMDecoder,
        samples: *mut *const c_float,
        frames: *mut c_int,
        error: *mut c_char,
        capacity: usize,
    ) -> c_int;
    fn gm_read_video(
        decoder: *mut GMDecoder,
        rgba: *mut *const c_uchar,
        stride: *mut c_int,
        seconds: *mut f64,
        error: *mut c_char,
        capacity: usize,
    ) -> c_int;
}

/// Size of the `error` scratch buffer every bridge call receives.
const ERROR_CAPACITY: usize = 512;

type ErrorBuffer = [c_char; ERROR_CAPACITY];

fn new_error_buffer() -> ErrorBuffer {
    [0; ERROR_CAPACITY]
}

/// Reads a bridge error buffer the way Swift's `String(cString:)` does.
///
/// The C side always leaves a `NUL` terminator in the buffer on failure, so this
/// never scans past the array.
fn error_message(buffer: &ErrorBuffer) -> String {
    // SAFETY: `buffer` is a live array of `ERROR_CAPACITY >= 1` bytes and the
    // bridge NUL-terminates every message it writes; an untouched buffer is all
    // zeros, i.e. the empty string.
    let text = unsafe { core::ffi::CStr::from_ptr(buffer.as_ptr()) };
    text.to_string_lossy().into_owned()
}

/// A demuxer plus codec context for one stream of one local file.
pub struct FileDecoder {
    handle: *mut GMDecoder,
}

// SAFETY: `FileDecoder` is a unique owner of its handle and the C bridge keeps no
// global state (each decoder owns an independent demuxer and codec context, see
// `CFFmpegBridge.h`). Moving it between threads is therefore sound; touching one
// decoder from two threads at once is not, which is why the readers in
// `readers.rs` serialize every call.
unsafe impl Send for FileDecoder {}

impl FileDecoder {
    /// `init(url:video:) throws`.
    pub fn new(url: &MediaUrl, video: bool) -> Result<Self, MediaError> {
        if !url.is_file_url() {
            return Err(MediaError::Invalid(
                "Media decoding requires a local file".to_string(),
            ));
        }
        let path = CString::new(url.path()).map_err(|_| {
            MediaError::Decoding("Media path contains an interior NUL byte".to_string())
        })?;
        let mut error = new_error_buffer();
        // SAFETY: `path` is a live NUL-terminated string and `error` is a live
        // buffer of `ERROR_CAPACITY` bytes, which is the capacity passed to the
        // bridge; the returned pointer is either null or an owned handle.
        let handle = unsafe {
            gm_open(
                path.as_ptr(),
                if video { 1 } else { 0 },
                error.as_mut_ptr(),
                ERROR_CAPACITY,
            )
        };
        if handle.is_null() {
            return Err(MediaError::Decoding(error_message(&error)));
        }
        Ok(FileDecoder { handle })
    }

    /// `var info: GMStreamInfo { gm_info(handle) }`.
    pub fn info(&self) -> GMStreamInfo {
        // SAFETY: `self.handle` is non-null and owned by `self`, which outlives
        // this call; `gm_info` is a pure read of the decoder's stream.
        unsafe { gm_info(self.handle) }
    }

    /// `func seek(to:) throws`.
    pub fn seek(&mut self, seconds: f64) -> Result<(), MediaError> {
        if !seconds.is_finite() || seconds < 0.0 {
            return Err(MediaError::Invalid(
                "Seek time must be finite and nonnegative".to_string(),
            ));
        }
        let mut error = new_error_buffer();
        // SAFETY: the handle is live; `error` is a writable buffer of the
        // capacity reported to the bridge.
        let status = unsafe { gm_seek(self.handle, seconds, error.as_mut_ptr(), ERROR_CAPACITY) };
        if status != 0 {
            return Err(MediaError::Decoding(error_message(&error)));
        }
        Ok(())
    }

    /// `func audio() throws -> PCMBuffer?`.
    pub fn audio(&mut self) -> Result<Option<PCMBuffer>, MediaError> {
        let mut samples: *const c_float = core::ptr::null();
        let mut frames: c_int = 0;
        let mut error = new_error_buffer();
        // SAFETY: the handle is live; the three out-parameters point at local
        // storage and `error` is writable with the reported capacity. The
        // returned sample pointer aliases the decoder's buffer, which the bridge
        // documents as valid until the next read/seek/close.
        let status = unsafe {
            gm_read_audio(
                self.handle,
                &mut samples,
                &mut frames,
                error.as_mut_ptr(),
                ERROR_CAPACITY,
            )
        };
        if status < 0 {
            return Err(MediaError::Decoding(error_message(&error)));
        }
        if status == 0 || samples.is_null() {
            return Ok(None);
        }
        let frame_count = frames.max(0) as usize;
        // SAFETY: on status 1 the bridge guarantees `frames` interleaved stereo
        // `float` pairs at `samples`, so `frames * 2 * size_of::<f32>()` bytes
        // are readable. The copy completes before the next bridge call.
        let bytes = unsafe {
            core::slice::from_raw_parts(
                samples.cast::<u8>(),
                frame_count * 2 * core::mem::size_of::<f32>(),
            )
        };
        Ok(Some(PCMBuffer::new(bytes.to_vec())))
    }

    /// `func video() throws -> VideoFrame?`.
    pub fn video(&mut self) -> Result<Option<VideoFrame>, MediaError> {
        let mut bytes: *const c_uchar = core::ptr::null();
        let mut stride: c_int = 0;
        let mut time: f64 = 0.0;
        let mut error = new_error_buffer();
        // SAFETY: the handle is live; out-parameters point at local storage and
        // `error` is writable with the reported capacity. The returned RGBA
        // pointer aliases the decoder's buffer until the next bridge call.
        let status = unsafe {
            gm_read_video(
                self.handle,
                &mut bytes,
                &mut stride,
                &mut time,
                error.as_mut_ptr(),
                ERROR_CAPACITY,
            )
        };
        if status < 0 {
            return Err(MediaError::Decoding(error_message(&error)));
        }
        if status == 0 || bytes.is_null() {
            return Ok(None);
        }
        // Swift re-reads `info` after the read, because the frame carries the
        // dimensions the scaler actually produced.
        let info = self.info();
        let stride = stride.max(0) as usize;
        let height = info.height.max(0) as usize;
        // SAFETY: on status 1 the bridge filled `stride * height` RGBA bytes at
        // `bytes`, and `stride` is the row pitch it also returns.
        let rgba = unsafe { core::slice::from_raw_parts(bytes, stride * height) };
        Ok(Some(VideoFrame {
            rgba: rgba.to_vec(),
            width: info.width.max(0) as usize,
            height,
            stride,
            time,
        }))
    }
}

impl Drop for FileDecoder {
    fn drop(&mut self) {
        // SAFETY: `self.handle` came from `gm_open` and is closed exactly once,
        // here, because `FileDecoder` is the sole owner.
        unsafe { gm_close(self.handle) };
    }
}
