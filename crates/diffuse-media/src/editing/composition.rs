//! Authored cuts. Decoder positions, GPU textures and playback clocks are
//! transient, so nothing here carries playback state.
//!
//! The JSON layout is Swift's synthesized `Codable` encoding (MIGRATION.md
//! §5.4): member-wise keys, every field optional on read with the Swift default
//! when absent, and no keys beyond `clips` and `video`.

use serde::{Deserialize, Deserializer, Serialize};

use crate::decoding::values::MediaError;

/// `MediaComposition.Video` — export raster.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct CompositionVideo {
    pub width: usize,
    pub height: usize,
    pub frames_per_second: usize,
}

impl Default for CompositionVideo {
    fn default() -> Self {
        // `public var width = 1920` / `height = 1080` / `framesPerSecond = 30`.
        CompositionVideo {
            width: 1920,
            height: 1080,
            frames_per_second: 30,
        }
    }
}

impl CompositionVideo {
    /// `public init()`.
    pub fn new() -> Self {
        Self::default()
    }

    /// `func validate() throws`.
    pub fn validate(&self) -> Result<(), MediaError> {
        let dimensions_ok = (2..=8192).contains(&self.width)
            && (2..=8192).contains(&self.height)
            && self.width.is_multiple_of(2)
            && self.height.is_multiple_of(2);
        if !dimensions_ok || !(1..=120).contains(&self.frames_per_second) {
            return Err(MediaError::Invalid(
                "Export requires even dimensions up to 8192 and 1...120 fps".to_string(),
            ));
        }
        Ok(())
    }
}

/// `private enum CodingKeys: CodingKey { case width, height, framesPerSecond }`
/// and the custom `init(from:)` that starts from `self.init()`.
///
/// Swift decodes each key with `decodeIfPresent(Int.self) ?? width`, so a missing
/// key keeps the default. `#[serde(default)]` on the fields reproduces that,
/// including the`keyNotFound` recovery, and `rename_all = "camelCase"` gives the
/// synthesized key `framesPerSecond`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct CompositionVideoWire {
    width: usize,
    height: usize,
    frames_per_second: usize,
}

impl Default for CompositionVideoWire {
    fn default() -> Self {
        let d = CompositionVideo::default();
        CompositionVideoWire {
            width: d.width,
            height: d.height,
            frames_per_second: d.frames_per_second,
        }
    }
}

impl<'de> Deserialize<'de> for CompositionVideo {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = CompositionVideoWire::deserialize(deserializer)?;
        Ok(CompositionVideo {
            width: wire.width,
            height: wire.height,
            frames_per_second: wire.frames_per_second,
        })
    }
}

/// `MediaComposition.Clip` — one authored cut.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompositionClip {
    pub source: String,
    pub start: f64,
    pub duration: f64,
}

impl CompositionClip {
    /// `init(source:start:duration:)` with the Swift default `start: 0`.
    pub fn new(source: impl Into<String>, start: f64, duration: f64) -> Self {
        CompositionClip {
            source: source.into(),
            start,
            duration,
        }
    }

    /// `init(source:duration:)` — the `start: 0` default argument.
    pub fn from_source(source: impl Into<String>, duration: f64) -> Self {
        CompositionClip::new(source, 0.0, duration)
    }

    /// `func validate() throws`.
    ///
    /// A clip source must be project-relative: non-empty, no leading `/`, no
    /// backslash, no `..` component and no `:` (which would allow a scheme or a
    /// Windows drive). The range must be finite, non-negative in its start,
    /// strictly positive in its duration, and finite after addition.
    pub fn validate(&self) -> Result<(), MediaError> {
        let relative = !self.source.is_empty()
            && !self.source.starts_with('/')
            && !self.source.contains('\\')
            && !self.source.split('/').any(|component| component == "..")
            && !self.source.contains(':');
        let in_range = self.start.is_finite()
            && self.start >= 0.0
            && self.duration.is_finite()
            && self.duration > 0.0
            && (self.start + self.duration).is_finite();
        if !relative || !in_range {
            return Err(MediaError::Invalid(
                "Clips require a project-relative file and a finite positive range".to_string(),
            ));
        }
        Ok(())
    }
}

/// Authored cuts; the persisted document.
///
/// `public init()` sets `clips = []` and `video = Video()`, which is exactly the
/// derived `Default`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct MediaComposition {
    pub clips: Vec<CompositionClip>,
    pub video: CompositionVideo,
}

/// `private enum CodingKeys: CodingKey { case clips, video }` with the same
/// `decodeIfPresent`-else-default treatment as [`CompositionVideo`]. `{}` decodes
/// to `MediaComposition()`, which is what the Swift test asserts.
#[derive(Deserialize)]
#[serde(default)]
struct MediaCompositionWire {
    clips: Vec<CompositionClip>,
    video: CompositionVideo,
}

impl Default for MediaCompositionWire {
    fn default() -> Self {
        let d = MediaComposition::default();
        MediaCompositionWire {
            clips: d.clips,
            video: d.video,
        }
    }
}

impl<'de> Deserialize<'de> for MediaComposition {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = MediaCompositionWire::deserialize(deserializer)?;
        Ok(MediaComposition {
            clips: wire.clips,
            video: wire.video,
        })
    }
}

impl MediaComposition {
    /// `public init()`.
    pub fn new() -> Self {
        Self::default()
    }

    /// `var duration: Double { clips.reduce(0) { $0 + $1.duration } }`.
    ///
    /// Summed in order, left to right, so the accumulated value matches Swift's
    /// `reduce` bit for bit.
    pub fn duration(&self) -> f64 {
        self.clips
            .iter()
            .fold(0.0_f64, |total, clip| total + clip.duration)
    }

    /// `public func validate() throws`.
    pub fn validate(&self) -> Result<(), MediaError> {
        if self.clips.is_empty() || self.clips.len() > 256 || !self.duration().is_finite() {
            return Err(MediaError::Invalid(
                "A composition requires 1...256 clips".to_string(),
            ));
        }
        self.video.validate()?;
        for clip in &self.clips {
            clip.validate()?;
        }
        Ok(())
    }
}

/// Decodes a composition from JSON bytes, reporting serde's message the way
/// `JSONDecoder` reports `DecodingError`.
pub fn decode_json(bytes: &[u8]) -> Result<MediaComposition, MediaError> {
    serde_json::from_slice(bytes).map_err(|error| MediaError::Invalid(error.to_string()))
}

/// Encodes a composition the way `JSONEncoder` does for this document: no
/// unknown keys and member-wise ordering `clips`, `video`.
pub fn encode_json(composition: &MediaComposition) -> Result<Vec<u8>, MediaError> {
    serde_json::to_vec(composition).map_err(|error| MediaError::Invalid(error.to_string()))
}
