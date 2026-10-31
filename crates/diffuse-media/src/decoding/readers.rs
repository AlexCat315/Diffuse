//! Streaming media readers and the bounded in-memory clip decoder.
//!
//! Swift declares `VideoReader` and `AudioReader` as actors so that one decoder is
//! never used from two tasks at once. MIGRATION.md §5.5 turns an actor into a
//! struct owning its state behind a lock; the lock preserves exactly that
//! serialization guarantee without an async runtime.

use std::sync::{Mutex, PoisonError};

use crate::decoding::decoder::FileDecoder;
use crate::decoding::values::{MediaError, MediaUrl, PCMBuffer, VideoFrame};

/// Serializes access to the decoder the way the Swift actor did.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // A panic while decoding leaves no partially-updated Rust state: the decoder
    // owns only its C handle, which stays usable. Recovering keeps the reader
    // semantics (a failure is reported per call, not as a poisoned actor).
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Streaming video reader; independent files and tracks do not share decoder
/// state.
pub struct VideoReader {
    decoder: Mutex<FileDecoder>,
}

impl VideoReader {
    /// `public init(url: URL) throws`.
    pub fn new(url: &MediaUrl) -> Result<Self, MediaError> {
        Ok(VideoReader {
            decoder: Mutex::new(FileDecoder::new(url, true)?),
        })
    }

    /// `public func nextFrame() throws -> VideoFrame?`.
    pub fn next_frame(&self) -> Result<Option<VideoFrame>, MediaError> {
        lock(&self.decoder).video()
    }

    /// `public func seek(to seconds: Double) throws`.
    pub fn seek(&self, seconds: f64) -> Result<(), MediaError> {
        lock(&self.decoder).seek(seconds)
    }

    /// `public func frame(at seconds: Double) throws -> VideoFrame?`.
    pub fn frame_at(&self, seconds: f64) -> Result<Option<VideoFrame>, MediaError> {
        let mut decoder = lock(&self.decoder);
        decoder.seek(seconds)?;
        decoder.video()
    }
}

/// Streaming audio reader.
pub struct AudioReader {
    decoder: Mutex<FileDecoder>,
}

impl AudioReader {
    /// `public init(url: URL) throws`.
    pub fn new(url: &MediaUrl) -> Result<Self, MediaError> {
        Ok(AudioReader {
            decoder: Mutex::new(FileDecoder::new(url, false)?),
        })
    }

    /// `public func nextBuffer() throws -> PCMBuffer?`.
    pub fn next_buffer(&self) -> Result<Option<PCMBuffer>, MediaError> {
        lock(&self.decoder).audio()
    }

    /// `public func seek(to seconds: Double) throws`.
    pub fn seek(&self, seconds: f64) -> Result<(), MediaError> {
        lock(&self.decoder).seek(seconds)
    }
}

/// `AudioFile`: bounded resident clips for SFX.
pub enum AudioFile {}

impl AudioFile {
    /// Default resident limit: 128 MiB of interleaved stereo PCM.
    pub const DEFAULT_MAXIMUM_BYTES: usize = 128 * 1024 * 1024;

    /// `decode(_:)` — the Swift default argument `maximumBytes: 128 * 1024 * 1024`.
    pub fn decode(url: &MediaUrl) -> Result<PCMBuffer, MediaError> {
        Self::decode_with_limit(url, Self::DEFAULT_MAXIMUM_BYTES)
    }

    /// `decode(_:maximumBytes:) throws -> PCMBuffer`.
    ///
    /// Long media should use [`AudioReader`]; this drains the whole stream into
    /// one buffer and refuses to exceed the resident limit.
    pub fn decode_with_limit(
        url: &MediaUrl,
        maximum_bytes: usize,
    ) -> Result<PCMBuffer, MediaError> {
        if maximum_bytes == 0 {
            return Err(MediaError::Invalid(
                "PCM byte limit must be positive".to_string(),
            ));
        }
        let mut decoder = FileDecoder::new(url, false)?;
        let mut samples: Vec<u8> = Vec::new();
        while let Some(chunk) = decoder.audio()? {
            // Swift traps on underflow here, and the invariant since the limit
            // is enforced above is `samples.len() <= maximum_bytes`.
            if chunk.samples.len() > maximum_bytes - samples.len() {
                return Err(MediaError::Invalid(
                    "Decoded audio exceeds the resident clip limit; use AudioReader for streaming"
                        .to_string(),
                ));
            }
            samples.extend_from_slice(&chunk.samples);
        }
        if samples.is_empty() {
            return Err(MediaError::Decoding(
                "Audio stream contains no samples".to_string(),
            ));
        }
        Ok(PCMBuffer::new(samples))
    }
}
