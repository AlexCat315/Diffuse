//! Decoded media values and the crate error type.
//!
//! Swift's `URL` and `Data` become [`MediaUrl`] and `Vec<u8>`: every entry point
//! in this crate takes a file URL, so [`MediaUrl`] keeps the original string and
//! the URL predicates the Swift code relied on (`isFileURL`, `path`,
//! `lastPathComponent`, `pathExtension`).

/// A string that is either a local file URL or a remote one.
///
/// Swift's `URL` accepts both; media decoding only ever opens local files, so
/// the distinction is a runtime check (`MediaError::Invalid`) rather than a type
/// distinction.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MediaUrl {
    raw: String,
}

impl MediaUrl {
    /// `URL(fileURLWithPath:)`: always a file URL.
    pub fn from_file_path(path: impl Into<String>) -> Self {
        MediaUrl { raw: path.into() }
    }

    /// `URL(string:)`. Returns `None` when the string is empty, matching the
    /// optional Swift initializer.
    pub fn parse(value: impl Into<String>) -> Option<Self> {
        let raw = value.into();
        if raw.is_empty() {
            return None;
        }
        if let Some(rest) = raw.strip_prefix("file://") {
            // `file://host/path` or `file:///path`.
            let path = match rest.find('/') {
                Some(index) => &rest[index..],
                None => "/",
            };
            return Some(MediaUrl {
                raw: path.to_string(),
            });
        }
        if let Some(path) = raw.strip_prefix("file:") {
            return Some(MediaUrl {
                raw: path.to_string(),
            });
        }
        Some(MediaUrl { raw })
    }

    /// `url.isFileURL`.
    pub fn is_file_url(&self) -> bool {
        match scheme(&self.raw) {
            Some(name) => name == "file",
            None => true,
        }
    }

    /// `url.path`: the filesystem path, without the `file:` scheme.
    pub fn path(&self) -> &str {
        &self.raw
    }

    /// `url.lastPathComponent`.
    pub fn last_path_component(&self) -> &str {
        match self.raw.rfind('/') {
            Some(index) => &self.raw[index + 1..],
            None => &self.raw,
        }
    }

    /// `url.pathExtension`: the suffix after the last dot of the last component.
    /// An empty string when there is none, and never including the dot.
    pub fn path_extension(&self) -> &str {
        let component = self.last_path_component();
        match component.rfind('.') {
            Some(index) if index > 0 => &component[index + 1..],
            _ => "",
        }
    }

    /// `url.appendingPathComponent(_:)`.
    pub fn appending_path_component(&self, component: &str) -> Self {
        if self.raw.ends_with('/') {
            MediaUrl {
                raw: format!("{}{}", self.raw, component),
            }
        } else {
            MediaUrl {
                raw: format!("{}/{}", self.raw, component),
            }
        }
    }

    /// `url.deletingLastPathComponent()`.
    pub fn deleting_last_path_component(&self) -> Self {
        let trimmed = self.raw.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(0) => MediaUrl {
                raw: "/".to_string(),
            },
            Some(index) => MediaUrl {
                raw: trimmed[..index].to_string(),
            },
            None => MediaUrl {
                raw: ".".to_string(),
            },
        }
    }

    /// `url.standardizedFileURL`: resolves `.` and `..` lexically.
    pub fn standardized_file_url(&self) -> Self {
        MediaUrl {
            raw: standardize(&self.raw),
        }
    }

    /// `url.resolvingSymlinksInPath()`.
    ///
    /// Falls back to the standardized path when the file does not exist, which
    /// is what `URL` does for unresolved components.
    pub fn resolving_symlinks_in_path(&self) -> Self {
        match std::fs::canonicalize(&self.raw) {
            Ok(path) => MediaUrl {
                raw: path.to_string_lossy().into_owned(),
            },
            Err(_) => self.standardized_file_url(),
        }
    }
}

impl core::fmt::Display for MediaUrl {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str(&self.raw)
    }
}

/// The RFC 3986 scheme of `value`, when it has one.
fn scheme(value: &str) -> Option<&str> {
    let colon = value.find(':')?;
    let candidate = &value[..colon];
    if candidate.is_empty() {
        return None;
    }
    let mut characters = candidate.chars();
    let first = characters.next()?;
    if !first.is_ascii_alphabetic() {
        return None;
    }
    if !characters
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.'))
    {
        return None;
    }
    // A bare Windows drive letter (`C:\media`) is a path, not a scheme.
    if candidate.len() == 1 && value[colon + 1..].starts_with(['\\', '/']) {
        return None;
    }
    Some(candidate)
}

/// Lexical `.`/`..` compaction, keeping a leading root.
fn standardize(path: &str) -> String {
    let rooted = path.starts_with('/');
    let mut components: Vec<&str> = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if matches!(components.last(), Some(last) if *last != "..") {
                    components.pop();
                } else if !rooted {
                    components.push("..");
                }
            }
            other => components.push(other),
        }
    }
    let joined = components.join("/");
    if rooted {
        format!("/{joined}")
    } else if joined.is_empty() {
        ".".to_string()
    } else {
        joined
    }
}

/// `MediaError`: the three failure domains the Swift runtime distinguished.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum MediaError {
    /// `case invalid(String)` — caller-supplied values that cannot be used.
    #[error("{0}")]
    Invalid(String),
    /// `case decoding(String)` — FFmpeg could not open or read the stream.
    #[error("{0}")]
    Decoding(String),
    /// `case export(String)` — the export worker failed.
    #[error("{0}")]
    Export(String),
}

impl MediaError {
    /// Swift's `errorDescription`: the payload for all three cases.
    pub fn error_description(&self) -> &str {
        match self {
            MediaError::Invalid(text) | MediaError::Decoding(text) | MediaError::Export(text) => {
                text
            }
        }
    }
}

/// Interleaved, native Float32 stereo PCM at 48 kHz, ready for an audio sink.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PCMBuffer {
    /// Interleaved stereo `f32` samples in the host's native byte order.
    pub samples: Vec<u8>,
}

impl PCMBuffer {
    /// Swift's internal `init(samples:)`.
    pub(crate) fn new(samples: Vec<u8>) -> Self {
        PCMBuffer { samples }
    }

    /// `var sampleRate: Int { 48000 }`.
    #[inline]
    pub fn sample_rate(&self) -> usize {
        48_000
    }

    /// `var channels: Int { 2 }`.
    #[inline]
    pub fn channels(&self) -> usize {
        2
    }

    /// `var frameCount: Int { samples.count / (2 * MemoryLayout<Float>.size) }`.
    #[inline]
    pub fn frame_count(&self) -> usize {
        self.samples.len() / (2 * core::mem::size_of::<f32>())
    }

    /// `var duration: Double { Double(frameCount) / Double(sampleRate) }`.
    #[inline]
    pub fn duration(&self) -> f64 {
        self.frame_count() as f64 / self.sample_rate() as f64
    }
}

/// One decoded video frame in tightly packed RGBA8.
#[derive(Clone, Debug, PartialEq)]
pub struct VideoFrame {
    pub rgba: Vec<u8>,
    pub width: usize,
    pub height: usize,
    /// Bytes per row. The C bridge always writes `width * 4`.
    pub stride: usize,
    /// Presentation time in seconds, relative to the stream start.
    pub time: f64,
}

/// `MediaAsset.Video`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaAssetVideo {
    pub width: usize,
    pub height: usize,
}

/// Stream facts read without decoding a frame.
#[derive(Clone, Debug, PartialEq)]
pub struct MediaAsset {
    pub duration: f64,
    pub video: Option<MediaAssetVideo>,
    pub has_audio: bool,
}

impl MediaAsset {
    /// `MediaAsset.inspect(_:)`.
    ///
    /// Both probes run even when the first fails, exactly like the two `try?`
    /// calls in Swift, so a file with only audio or only video still inspects.
    pub fn inspect(url: &MediaUrl) -> Result<Self, MediaError> {
        let audio = crate::decoding::decoder::FileDecoder::new(url, false).ok();
        let video = crate::decoding::decoder::FileDecoder::new(url, true).ok();
        if audio.is_none() && video.is_none() {
            return Err(MediaError::Decoding(format!(
                "No supported media streams: {}",
                url.last_path_component()
            )));
        }
        let audio_duration = audio
            .as_ref()
            .map_or(0.0, |decoder| decoder.info().duration);
        let video_duration = video
            .as_ref()
            .map_or(0.0, |decoder| decoder.info().duration);
        Ok(MediaAsset {
            duration: audio_duration.max(video_duration),
            video: video.map(|decoder| {
                let info = decoder.info();
                MediaAssetVideo {
                    // `Int(info.width)`: the bridge only reports non-negative
                    // codec dimensions, so this is the same value widened.
                    width: info.width.max(0) as usize,
                    height: info.height.max(0) as usize,
                }
            }),
            has_audio: audio.is_some(),
        })
    }
}
