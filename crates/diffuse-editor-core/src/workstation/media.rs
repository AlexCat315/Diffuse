//! Translation of `Editor/Sources/EditorCore/Workstation/Media.swift`.
//!
//! The project's authored video timeline: its clips, the persisted
//! `.cove/media.json` document and the preview/playback/export entry points.
//!
//! Swift's `@unchecked Sendable` class becomes a struct whose mutable state
//! sits behind a mutex (MIGRATION.md §5.5), the same shape
//! [`EditorDocumentWorkspace`](crate::workstation::documents::EditorDocumentWorkspace)
//! uses.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cove_media::VideoFrame;
use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_audio::playback::media_player::MediaPlayer;
use diffuse_media::MediaAsset;
use diffuse_media::MediaError;
use diffuse_media::MediaUrl;
use diffuse_media::editing::composition::{CompositionClip, MediaComposition};
use diffuse_media::editing::export::MediaExporter;

struct MediaState {
    saved_data: Option<Vec<u8>>,
    composition: MediaComposition,
    is_dirty: bool,
    error: Option<String>,
}

pub struct EditorMediaWorkspace {
    root: MediaUrl,
    document_url: MediaUrl,
    state: Mutex<MediaState>,
    observers: Mutex<BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>>,
    next_observer: AtomicU64,
}

impl EditorMediaWorkspace {
    /// `public init(root: URL) throws`.
    pub fn new(root: &Path) -> Result<Self, MediaError> {
        let root = MediaUrl::from_file_path(root.to_string_lossy())
            .resolving_symlinks_in_path()
            .standardized_file_url();
        let document_url = root.appending_path_component(".cove/media.json");
        let mut state = MediaState {
            saved_data: None,
            composition: MediaComposition::new(),
            is_dirty: false,
            error: None,
        };
        if Path::new(document_url.path()).exists() {
            let saved = std::fs::read(document_url.path())
                .map_err(|error| MediaError::Decoding(error.to_string()))?;
            let composition: MediaComposition = serde_json::from_slice(&saved)
                .map_err(|error| MediaError::Decoding(error.to_string()))?;
            if !composition.clips.is_empty() {
                composition.validate()?;
            }
            state.saved_data = Some(saved);
            state.composition = composition;
        }
        Ok(EditorMediaWorkspace {
            root,
            document_url,
            state: Mutex::new(state),
            observers: Mutex::new(BTreeMap::new()),
            next_observer: AtomicU64::new(0),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, MediaState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn composition(&self) -> MediaComposition {
        self.lock().composition.clone()
    }

    pub fn is_dirty(&self) -> bool {
        self.lock().is_dirty
    }

    pub fn error(&self) -> Option<String> {
        self.lock().error.clone()
    }

    pub fn add(&self, path: &str) -> Result<(), MediaError> {
        let clip = CompositionClip::from_source(path, 1.0);
        let mut candidate = MediaComposition::new();
        candidate.clips = vec![clip];
        candidate.validate()?;
        let asset = MediaAsset::inspect(&self.source_url(path)?)?;
        if asset.video.is_none()
            || asset.duration.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater)
        {
            return Err(MediaError::Invalid(
                "Select a video file with a known duration".to_string(),
            ));
        }
        {
            let mut state = self.lock();
            state
                .composition
                .clips
                .push(CompositionClip::from_source(path, asset.duration));
            state.is_dirty = true;
        }
        self.publish();
        Ok(())
    }

    pub fn trim(&self, index: usize, start: f64, duration: f64) -> Result<(), MediaError> {
        let clips = self.lock().composition.clips.clone();
        let Some(clip) = clips.get(index).cloned() else {
            return Ok(());
        };
        let mut candidate = self.lock().composition.clone();
        candidate.clips[index].start = start;
        candidate.clips[index].duration = duration;
        candidate.validate()?;
        let asset = MediaAsset::inspect(&self.source_url(&clip.source)?)?;
        if !matches!(
            (start + duration).partial_cmp(&(asset.duration + 0.001)),
            Some(std::cmp::Ordering::Less | std::cmp::Ordering::Equal)
        ) {
            return Err(MediaError::Invalid(
                "Trim range exceeds the source duration".to_string(),
            ));
        }
        {
            let mut state = self.lock();
            state.composition = candidate;
            state.is_dirty = true;
        }
        self.publish();
        Ok(())
    }

    pub fn remove(&self, index: usize) {
        let mut state = self.lock();
        if index >= state.composition.clips.len() {
            return;
        }
        state.composition.clips.remove(index);
        state.is_dirty = true;
        drop(state);
        self.publish();
    }

    /// Swift's `move(_:by:)`; `move` is a Rust keyword.
    pub fn move_by(&self, index: usize, offset: i64) {
        let destination = index as i64 + offset;
        let mut state = self.lock();
        let count = state.composition.clips.len();
        if index >= count || destination < 0 || destination as usize >= count {
            return;
        }
        state.composition.clips.swap(index, destination as usize);
        state.is_dirty = true;
        drop(state);
        self.publish();
    }

    #[must_use]
    pub fn save(&self) -> bool {
        let result = (|| -> Result<(), MediaError> {
            let composition = self.composition();
            if !composition.clips.is_empty() {
                composition.validate()?;
            }
            let directory =
                Path::new(self.document_url.deleting_last_path_component().path()).to_path_buf();
            std::fs::create_dir_all(&directory)
                .map_err(|error| MediaError::Decoding(error.to_string()))?;
            // `outputFormatting = [.prettyPrinted, .sortedKeys]`.
            let current = if Path::new(self.document_url.path()).exists() {
                Some(
                    std::fs::read(self.document_url.path())
                        .map_err(|error| MediaError::Decoding(error.to_string()))?,
                )
            } else {
                None
            };
            if current != self.lock().saved_data {
                return Err(MediaError::Invalid(
                    "The media timeline changed on disk; reopen the project before saving"
                        .to_string(),
                ));
            }
            let text = diffuse_assets::swift_json::to_sorted_pretty(&composition)
                .map_err(|error| MediaError::Invalid(error.to_string()))?;
            let data = text.into_bytes();
            AtomicFile::write(&data, Path::new(self.document_url.path()), Access::Inherit)
                .map_err(|error| MediaError::Decoding(error.to_string()))?;
            let mut state = self.lock();
            state.saved_data = Some(data);
            state.is_dirty = false;
            state.error = None;
            Ok(())
        })();
        let failure = result
            .err()
            .map(|error| error.error_description().to_string());
        self.lock().error = failure;
        let saved = self.lock().error.is_none();
        self.publish();
        saved
    }

    /// `func preview(_:at:) async throws -> VideoFrame?`.
    ///
    /// `VideoReader` was deleted with the 8.1.3 decode stack (MIGRATION.md §8,
    /// `diffuse-media`), so the one-frame read comes from the audio runtime's
    /// player, which owns decoding.
    pub fn preview(&self, index: usize, at: f64) -> Result<Option<VideoFrame>, MediaError> {
        let clips = self.lock().composition.clips.clone();
        let Some(clip) = clips.get(index).cloned() else {
            return Ok(None);
        };
        let url = self.source_url(&clip.source)?;
        MediaPlayer::new().frame_at(&url, clip.start + clip.duration.min(0.0_f64.max(at)))
    }

    pub fn play(
        &self,
        index: usize,
        on_video: Arc<dyn Fn(VideoFrame) + Send + Sync>,
    ) -> Result<(), MediaError> {
        let clips = self.lock().composition.clips.clone();
        let Some(clip) = clips.get(index).cloned() else {
            return Ok(());
        };
        let url = self.source_url(&clip.source)?;
        MediaPlayer::new().play(&url, clip.start, Some(clip.duration), on_video)
    }

    pub fn export(&self, to: &MediaUrl, executable: &Path) -> Result<(), MediaError> {
        MediaExporter::new(executable).export(&self.composition(), &self.root, to)
    }

    fn source_url(&self, path: &str) -> Result<MediaUrl, MediaError> {
        let mut candidate = MediaComposition::new();
        candidate.clips = vec![CompositionClip::from_source(path, 1.0)];
        candidate.validate()?;
        let mut url = self.root.clone();
        // Swift's `path.split(separator: "/")` omits empty subsequences.
        for part in path.split('/').filter(|part| !part.is_empty()) {
            url = url.appending_path_component(part);
            let is_symbolic_link = std::fs::symlink_metadata(Path::new(url.path()))
                .map(|metadata| metadata.file_type().is_symlink())
                .unwrap_or(false);
            if is_symbolic_link {
                return Err(MediaError::Invalid(
                    "Media source must remain inside the project".to_string(),
                ));
            }
        }
        Ok(url)
    }

    fn publish(&self) {
        let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
            .observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for handler in handlers {
            handler();
        }
    }

    pub fn register_observer(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        let token = self.next_observer.fetch_add(1, Ordering::SeqCst);
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(token, handler);
        token
    }

    pub fn unregister_observer(&self, token: u64) {
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&token);
    }
}
