//! `ContextMemoryStore.swift` — long-term AI context memory persisted as JSON.
//!
//! Swift's `actor` becomes a `Mutex`-guarded `BTreeMap` (MIGRATION.md §5.5);
//! every accessor takes `&self` so callers share the store by reference.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use cove_system::files::{Access, atomic_write};
use diffuse_intent::transactions::world_event::WorldEvent;

use crate::context_entry::{ContextEntry, EntryKind};
use crate::reducers::{ContextMemoryMutation, ReducerRegistry};

#[derive(Debug, thiserror::Error)]
pub enum ContextMemoryError {
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Json(#[from] serde_json::Error),
}

/// Long-term AI context memory, persisted as a JSON file between sessions.
///
/// Entries are produced by a `ReducerRegistry` applied to incoming `WorldEvent`s.
/// Reducers are pure, so replaying the same event sequence is deterministic.
pub struct ContextMemoryStore {
    entries: Mutex<BTreeMap<String, ContextEntry>>,
    reducers: ReducerRegistry,
    capacity: usize,
    storage_url: Option<PathBuf>,
}

impl ContextMemoryStore {
    /// Swift `init(reducers: .default, capacity: 512, storageURL: nil)`.
    pub fn new() -> Result<Self, ContextMemoryError> {
        Self::with_options(ReducerRegistry::default(), 512, None)
    }

    pub fn with_capacity(capacity: usize) -> Result<Self, ContextMemoryError> {
        Self::with_options(ReducerRegistry::default(), capacity, None)
    }

    pub fn with_storage(storage_url: impl Into<PathBuf>) -> Result<Self, ContextMemoryError> {
        Self::with_options(ReducerRegistry::default(), 512, Some(storage_url.into()))
    }

    pub fn with_options(
        reducers: ReducerRegistry,
        capacity: usize,
        storage_url: Option<PathBuf>,
    ) -> Result<Self, ContextMemoryError> {
        let mut entries = BTreeMap::new();
        if let Some(url) = &storage_url
            && url.exists()
        {
            let data = std::fs::read(url)?;
            let loaded: Vec<ContextEntry> = serde_json::from_slice(&data)?;
            for item in loaded {
                entries.insert(item.id.clone(), item);
            }
        }
        Ok(ContextMemoryStore {
            entries: Mutex::new(entries),
            reducers,
            capacity: capacity.max(1),
            storage_url,
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, ContextEntry>> {
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Applies `event` through all registered reducers and applies the mutations.
    pub fn apply(&self, event: &WorldEvent) {
        let mut entries = self.lock();
        let mutations = self.reducers.apply(&entries, event);
        for mutation in mutations {
            match mutation {
                ContextMemoryMutation::Upsert(item) => {
                    entries.insert(item.id.clone(), item);
                }
                ContextMemoryMutation::Delete { id } => {
                    entries.remove(&id);
                }
            }
        }
        evict_if_needed(&mut entries, self.capacity);
    }

    /// Applies a batch of events in order.
    pub fn apply_events(&self, events: &[WorldEvent]) {
        for event in events {
            self.apply(event);
        }
    }

    /// Directly upserts an entry without going through the reducer pipeline.
    pub fn upsert(&self, item: ContextEntry) {
        let mut entries = self.lock();
        entries.insert(item.id.clone(), item);
        evict_if_needed(&mut entries, self.capacity);
    }

    pub fn remove(&self, id: &str) {
        self.lock().remove(id);
    }

    pub fn lookup_subject(&self, subject: &str) -> Vec<ContextEntry> {
        let entries = self.lock();
        ranked(&entries)
            .into_iter()
            .filter(|item| item.subject == subject)
            .collect()
    }

    pub fn lookup_kind(&self, kind: EntryKind) -> Vec<ContextEntry> {
        let entries = self.lock();
        ranked(&entries)
            .into_iter()
            .filter(|item| item.kind == kind)
            .collect()
    }

    pub fn entry(&self, id: &str) -> Option<ContextEntry> {
        self.lock().get(id).cloned()
    }

    pub fn all_entries(&self) -> Vec<ContextEntry> {
        ranked(&self.lock())
    }

    /// LLM-safe dictionary view of the most important entries, capped at `budget`.
    pub fn symbolic_view(&self, budget: usize) -> Vec<BTreeMap<String, String>> {
        ranked(&self.lock())
            .into_iter()
            .take(budget)
            .map(|item| {
                let mut view = BTreeMap::from([
                    ("id".to_string(), item.id),
                    ("kind".to_string(), item.kind.as_str().to_string()),
                    ("subject".to_string(), item.subject),
                ]);
                view.extend(item.payload);
                view
            })
            .collect()
    }

    /// Persists all entries to `storage_url` (if configured).
    pub fn flush(&self) -> Result<(), ContextMemoryError> {
        let Some(url) = &self.storage_url else {
            return Ok(());
        };
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // `BTreeMap` already iterates by id, matching Swift's sorted `all`.
        let all: Vec<ContextEntry> = self.lock().values().cloned().collect();
        let data = serde_json::to_vec(&all)?;
        atomic_write(url, &data, Access::Inherit)?;
        Ok(())
    }
}

/// Swift sorted by descending importance. An id tiebreak keeps the order
/// deterministic, as MIGRATION.md §5.2 requires for anything observable.
fn ranked(entries: &BTreeMap<String, ContextEntry>) -> Vec<ContextEntry> {
    let mut all: Vec<ContextEntry> = entries.values().cloned().collect();
    all.sort_by(|left, right| {
        right
            .importance
            .total_cmp(&left.importance)
            .then_with(|| left.id.cmp(&right.id))
    });
    all
}

/// Evict by ascending importance, breaking ties by ascending timestamp
/// (oldest first), then id.
fn evict_if_needed(entries: &mut BTreeMap<String, ContextEntry>, capacity: usize) {
    if entries.len() <= capacity {
        return;
    }
    let mut all: Vec<ContextEntry> = entries.values().cloned().collect();
    all.sort_by(|left, right| {
        left.importance
            .total_cmp(&right.importance)
            .then_with(|| left.timestamp.total_cmp(&right.timestamp))
            .then_with(|| left.id.cmp(&right.id))
    });
    let remove_count = entries.len() - capacity;
    for item in all.into_iter().take(remove_count) {
        entries.remove(&item.id);
    }
}
