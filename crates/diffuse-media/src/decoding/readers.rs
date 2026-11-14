//! Independent streaming readers and bounded resident audio clips.

use std::sync::{Mutex, MutexGuard};

use cove_media::{
    AudioBuffer, AudioFormat, DecoderOptions, MediaDecoder, MediaSource, MediaTime, VideoFrame,
};

use super::values::{MediaError, MediaUrl};

fn open(url: &MediaUrl, video: bool) -> Result<MediaDecoder, MediaError> {
    if !url.is_file_url() {
        return Err(MediaError::Invalid(
            "Media decoding requires a local file".into(),
        ));
    }
    let options = if video {
        DecoderOptions::video_only()
    } else {
        DecoderOptions {
            audio_format: Some(AudioFormat {
                sample_rate: 48_000,
                channels: 2,
            }),
            ..DecoderOptions::audio_only()
        }
    };
    let decoder = MediaDecoder::open(MediaSource::file(url.path()), options)
        .map_err(|error| MediaError::Decoding(error.message))?;
    if (video && decoder.video_stream().is_none()) || (!video && decoder.audio_stream().is_none()) {
        return Err(MediaError::Decoding("No supported media stream".into()));
    }
    Ok(decoder)
}

fn seek(decoder: &mut MediaDecoder, seconds: f64) -> Result<(), MediaError> {
    let time = MediaTime::from_seconds(seconds)
        .map_err(|_| MediaError::Invalid("Seek time must be finite and nonnegative".into()))?;
    decoder
        .seek(time)
        .map_err(|error| MediaError::Decoding(error.message))
}

/// Each reader serializes its own decoder, corresponding to Swift actor isolation.
pub struct VideoReader {
    decoder: Mutex<MediaDecoder>,
}
impl VideoReader {
    pub fn new(url: &MediaUrl) -> Result<Self, MediaError> {
        Ok(Self {
            decoder: Mutex::new(open(url, true)?),
        })
    }
    fn lock(&self) -> MutexGuard<'_, MediaDecoder> {
        self.decoder
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }
    pub fn next_frame(&self) -> Result<Option<VideoFrame>, MediaError> {
        self.lock()
            .next_video()
            .map_err(|error| MediaError::Decoding(error.message))
    }
    pub fn seek(&self, seconds: f64) -> Result<(), MediaError> {
        seek(&mut self.lock(), seconds)
    }
    pub fn frame_at(&self, seconds: f64) -> Result<Option<VideoFrame>, MediaError> {
        let mut decoder = self.lock();
        seek(&mut decoder, seconds)?;
        decoder
            .next_video()
            .map_err(|error| MediaError::Decoding(error.message))
    }
}

/// Each reader owns an independent audio decoder resampling to stereo at 48 kHz.
pub struct AudioReader {
    decoder: Mutex<MediaDecoder>,
}
impl AudioReader {
    pub fn new(url: &MediaUrl) -> Result<Self, MediaError> {
        Ok(Self {
            decoder: Mutex::new(open(url, false)?),
        })
    }
    fn lock(&self) -> MutexGuard<'_, MediaDecoder> {
        self.decoder
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }
    pub fn next_buffer(&self) -> Result<Option<AudioBuffer>, MediaError> {
        self.lock()
            .next_audio()
            .map_err(|error| MediaError::Decoding(error.message))
    }
    pub fn seek(&self, seconds: f64) -> Result<(), MediaError> {
        seek(&mut self.lock(), seconds)
    }
}

pub struct AudioFile;
impl AudioFile {
    pub const DEFAULT_MAXIMUM_BYTES: usize = 128 * 1024 * 1024;
    pub fn decode(url: &MediaUrl) -> Result<AudioBuffer, MediaError> {
        Self::decode_with_limit(url, Self::DEFAULT_MAXIMUM_BYTES)
    }
    pub fn decode_with_limit(
        url: &MediaUrl,
        maximum_bytes: usize,
    ) -> Result<AudioBuffer, MediaError> {
        if maximum_bytes == 0 {
            return Err(MediaError::Invalid(
                "PCM byte limit must be positive".into(),
            ));
        }
        let reader = AudioReader::new(url)?;
        let mut samples = Vec::new();
        while let Some(chunk) = reader.next_buffer()? {
            let remaining = maximum_bytes / size_of::<f32>() - samples.len();
            if chunk.samples.len() > remaining {
                return Err(MediaError::Invalid(
                    "Decoded audio exceeds the resident clip limit; use AudioReader for streaming"
                        .into(),
                ));
            }
            samples.extend(chunk.samples);
        }
        if samples.is_empty() {
            return Err(MediaError::Decoding(
                "Audio stream contains no samples".into(),
            ));
        }
        Ok(AudioBuffer {
            pts: None,
            format: AudioFormat {
                sample_rate: 48_000,
                channels: 2,
            },
            samples,
        })
    }
}
