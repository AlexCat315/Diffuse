//! `FileBackedSemanticMemoryStore.swift` — persistent `SemanticMemoryStore`.
//!
//! Swift's `actor` becomes a `Mutex`-guarded index (MIGRATION.md §5.5); entries
//! are persisted as a sorted JSON array so the file bytes are deterministic.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use cove_system::files::{Access, atomic_write};

use crate::memory::semantic_memory_store::{
    MemoryScope, MemorySource, SemanticMemoryEntry, SemanticMemoryError, SemanticMemoryStore,
};
use crate::semantic_contracts::{
    GeometryFingerprint, SemanticConfirmation, SemanticConfirmationOutcome,
};

/// Persistent `SemanticMemoryStore` that survives app restarts.
///
/// Entries are stored as a JSON array at `storage_url`. Writes are synchronous and
/// lock-isolated; the file is always current after `record` returns.
pub struct FileBackedSemanticMemoryStore {
    storage_url: PathBuf,
    index: Mutex<BTreeMap<String, Vec<SemanticMemoryEntry>>>,
}

impl FileBackedSemanticMemoryStore {
    pub fn new(storage_url: impl Into<PathBuf>) -> Result<Self, SemanticMemoryError> {
        let storage_url = storage_url.into();
        if let Some(dir) = storage_url.parent() {
            std::fs::create_dir_all(dir)?;
        }

        let mut index: BTreeMap<String, Vec<SemanticMemoryEntry>> = BTreeMap::new();
        if storage_url.exists() {
            let data = std::fs::read(&storage_url)?;
            let all: Vec<SemanticMemoryEntry> = serde_json::from_slice(&data)?;
            for entry in all {
                index
                    .entry(entry.fingerprint_hash.clone())
                    .or_default()
                    .push(entry);
            }
        }

        Ok(FileBackedSemanticMemoryStore {
            storage_url,
            index: Mutex::new(index),
        })
    }

    /// Adds a raw entry directly (e.g. for bulk import from legacy stores).
    pub fn insert(&self, entry: SemanticMemoryEntry) -> Result<(), SemanticMemoryError> {
        let mut guard = self.lock();
        let mut next = guard.clone();
        next.entry(entry.fingerprint_hash.clone())
            .or_default()
            .push(entry);
        self.persist(&next)?;
        *guard = next;
        Ok(())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Vec<SemanticMemoryEntry>>> {
        self.index
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn persist(
        &self,
        index: &BTreeMap<String, Vec<SemanticMemoryEntry>>,
    ) -> Result<(), SemanticMemoryError> {
        let mut all: Vec<&SemanticMemoryEntry> = index.values().flatten().collect();
        all.sort_by(|a, b| {
            a.fingerprint_hash
                .cmp(&b.fingerprint_hash)
                .then_with(|| a.region_alias.cmp(&b.region_alias))
                .then_with(|| {
                    a.updated_at
                        .0
                        .partial_cmp(&b.updated_at.0)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        });
        let data = serde_json::to_vec(&all)?;
        atomic_write(&self.storage_url, &data, Access::Inherit)?;
        Ok(())
    }

    fn hash_key(fingerprint: &GeometryFingerprint) -> String {
        format!(
            "{}:{}:{}:{}",
            fingerprint.genus,
            fingerprint.boundary_loops,
            fingerprint.face_count_bucket,
            fingerprint.version
        )
    }
}

impl SemanticMemoryStore for FileBackedSemanticMemoryStore {
    fn lookup(&self, fingerprint: &GeometryFingerprint) -> Vec<SemanticMemoryEntry> {
        self.lock()
            .get(&Self::hash_key(fingerprint))
            .cloned()
            .unwrap_or_default()
    }

    fn record(
        &self,
        region_id: &str,
        fingerprint: &GeometryFingerprint,
        confirmation: &SemanticConfirmation,
    ) -> Result<(), SemanticMemoryError> {
        let SemanticConfirmationOutcome::Accepted(label) = &confirmation.outcome else {
            return Ok(());
        };
        let key = Self::hash_key(fingerprint);
        let entry = SemanticMemoryEntry::new(
            key.clone(),
            confirmation.region_id.clone(),
            region_id,
            label,
            MemoryScope::Asset,
            MemorySource::Confirmed,
            1.0,
            confirmation.confirmed_at,
        );

        let mut guard = self.lock();
        let mut next = guard.clone();
        next.entry(key).or_default().push(entry);
        self.persist(&next)?;
        *guard = next;
        Ok(())
    }
}
