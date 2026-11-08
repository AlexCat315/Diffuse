//! `LocalArtifactStore.swift` — content-addressed store for binary artifacts.
//!
//! Swift's `actor` becomes a `Mutex`-guarded index (MIGRATION.md §5.5); every
//! accessor takes `&self` so callers share the store by reference.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use cove_system::files::{Access, atomic_write};

use crate::core::perception_contracts::ArtifactRef;
use crate::support::sha256_portable::SHA256Portable;

#[derive(Debug, thiserror::Error)]
pub enum ArtifactStoreError {
    #[error("Artifact not found in local store: {uri}")]
    NotFound { uri: String },
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

impl ArtifactStoreError {
    pub fn not_found(uri: impl Into<String>) -> Self {
        ArtifactStoreError::NotFound { uri: uri.into() }
    }
}

/// Content-addressed store for large binary artifacts (embeddings, masks, depth maps).
///
/// Artifacts are indexed by SHA-256 of content so identical data is never stored
/// twice; the `artifacts://` URI scheme resolves back to a file path.
pub struct LocalArtifactStore {
    base_url: PathBuf,
    index: Mutex<BTreeMap<String, PathBuf>>,
}

impl LocalArtifactStore {
    pub fn new(base_url: impl Into<PathBuf>) -> Result<Self, ArtifactStoreError> {
        let base_url = base_url.into();
        std::fs::create_dir_all(&base_url)?;
        Ok(LocalArtifactStore {
            base_url,
            index: Mutex::new(BTreeMap::new()),
        })
    }

    pub fn base_url(&self) -> &Path {
        &self.base_url
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, PathBuf>> {
        self.index
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Writes `data` into the store and returns an `ArtifactRef` whose URI is
    /// `artifacts://<sha256>`. Idempotent: identical content reuses the existing file.
    pub fn write(
        &self,
        data: &[u8],
        media_type: &str,
        semantic_kind: &str,
        redaction: &str,
    ) -> Result<ArtifactRef, ArtifactStoreError> {
        let hash = SHA256Portable::hex_digest(data);
        let extension = file_extension(media_type);
        let file_url = self.base_url.join(format!("{hash}.{extension}"));
        if !file_url.exists() {
            atomic_write(&file_url, data, Access::Inherit)?;
        }
        self.lock().insert(hash.clone(), file_url);
        Ok(ArtifactRef::with_options(
            format!("artifacts://{hash}"),
            Some(hash),
            media_type,
            semantic_kind,
            redaction,
        ))
    }

    /// Swift's default `redaction: "prompt_forbidden"`.
    pub fn write_with_default_redaction(
        &self,
        data: &[u8],
        media_type: &str,
        semantic_kind: &str,
    ) -> Result<ArtifactRef, ArtifactStoreError> {
        self.write(data, media_type, semantic_kind, "prompt_forbidden")
    }

    /// Resolves an `artifacts://` URI to the local file path, or `None` when the
    /// artifact is not present in this store.
    pub fn resolve(&self, artifact_ref: &ArtifactRef) -> Option<PathBuf> {
        let hash = artifact_ref.uri.strip_prefix("artifacts://")?;
        if let Some(cached) = self.lock().get(hash) {
            return cached.exists().then(|| cached.clone());
        }
        let extension = file_extension(&artifact_ref.media_type);
        let candidate = self.base_url.join(format!("{hash}.{extension}"));
        candidate.exists().then_some(candidate)
    }

    pub fn read(&self, artifact_ref: &ArtifactRef) -> Result<Vec<u8>, ArtifactStoreError> {
        let Some(url) = self.resolve(artifact_ref) else {
            return Err(ArtifactStoreError::not_found(artifact_ref.uri.clone()));
        };
        Ok(std::fs::read(url)?)
    }
}

fn file_extension(media_type: &str) -> &'static str {
    match media_type {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "application/json" => "json",
        _ => "bin",
    }
}
