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
        let separator = if cfg!(windows) {
            self.raw.rfind(['/', '\\'])
        } else {
            self.raw.rfind('/')
        };
        match separator {
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
        #[cfg(windows)]
        if self.is_file_url() {
            return MediaUrl {
                raw: std::path::Path::new(&self.raw)
                    .join(component)
                    .to_string_lossy()
                    .into_owned(),
            };
        }
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
        #[cfg(windows)]
        if self.is_file_url() {
            let path = std::path::Path::new(&self.raw);
            return MediaUrl {
                raw: path
                    .parent()
                    .filter(|parent| !parent.as_os_str().is_empty())
                    .unwrap_or_else(|| std::path::Path::new("."))
                    .to_string_lossy()
                    .into_owned(),
            };
        }
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
    #[cfg(windows)]
    {
        use std::path::{Component, Path, PathBuf};
        let mut result = PathBuf::new();
        for component in Path::new(path).components() {
            match component {
                Component::CurDir => {}
                Component::ParentDir => {
                    if result.file_name().is_some_and(|name| name != "..") {
                        result.pop();
                    } else if !result.has_root() {
                        result.push("..");
                    }
                }
                other => result.push(other.as_os_str()),
            }
        }
        if result.as_os_str().is_empty() {
            ".".into()
        } else {
            result.to_string_lossy().into_owned()
        }
    }
    #[cfg(not(windows))]
    {
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
}

/// Media failures, including cancellation which Swift throws separately.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum MediaError {
    /// `case invalid(String)` - caller-supplied values that cannot be used.
    #[error("{0}")]
    Invalid(String),
    /// `case decoding(String)` - the media could not be opened or probed.
    #[error("{0}")]
    Decoding(String),
    /// `case export(String)` - the export worker failed.
    #[error("{0}")]
    Export(String),
    #[error("media input cancelled")]
    Cancelled,
}

impl MediaError {
    /// Swift's `errorDescription`: the payload for all three cases.
    pub fn error_description(&self) -> &str {
        match self {
            MediaError::Invalid(text) | MediaError::Decoding(text) | MediaError::Export(text) => {
                text
            }
            MediaError::Cancelled => "media input cancelled",
        }
    }
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
    /// Inspect each kind using its successfully opened decoder, as in Swift.
    pub fn inspect(url: &MediaUrl) -> Result<Self, MediaError> {
        use cove_media::{DecoderOptions, MediaDecoder, MediaSource};

        let open = |options| {
            url.is_file_url()
                .then(|| MediaDecoder::open(MediaSource::file(url.path()), options).ok())
                .flatten()
        };
        let audio = open(DecoderOptions::audio_only());
        let video = open(DecoderOptions::video_only());
        let audio_stream = audio.as_ref().and_then(MediaDecoder::audio_stream);
        let video_stream = video.as_ref().and_then(MediaDecoder::video_stream);
        if audio_stream.is_none() && video_stream.is_none() {
            return Err(MediaError::Decoding(format!(
                "No supported media streams: {}",
                url.last_path_component()
            )));
        }
        let duration = |decoder: Option<&MediaDecoder>, stream: Option<&cove_media::StreamInfo>| {
            stream
                .and_then(|stream| stream.duration)
                .or_else(|| decoder.and_then(|decoder| decoder.info().duration))
                .map_or(0.0, |duration| duration.seconds())
        };
        let dimensions =
            video
                .as_ref()
                .and_then(MediaDecoder::video_dimensions)
                .map(|(width, height)| MediaAssetVideo {
                    width: width as usize,
                    height: height as usize,
                });
        Ok(MediaAsset {
            duration: duration(audio.as_ref(), audio_stream)
                .max(duration(video.as_ref(), video_stream)),
            video: dimensions,
            has_audio: audio_stream.is_some(),
        })
    }
}
