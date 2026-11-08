//! `SemanticMemoryStore.swift` — cross-session label memory contracts.

use std::collections::BTreeMap;
use std::sync::Mutex;

use diffuse_kernel::codable::serialize_float;
use diffuse_perception::SwiftDate;
use serde::{Deserialize, Serialize};

use crate::semantic_contracts::{
    GeometryFingerprint, SemanticConfirmation, SemanticConfirmationOutcome,
};

#[derive(Debug, thiserror::Error)]
pub enum SemanticMemoryError {
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("semantic memory JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticMemoryEntry {
    pub fingerprint_hash: String,
    pub asset_uri: String,
    pub region_alias: String,
    pub label: String,
    pub scope: MemoryScope,
    pub source: MemorySource,
    #[serde(serialize_with = "serialize_float")]
    pub confidence: f32,
    pub updated_at: SwiftDate,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryScope {
    Asset,
    Family,
    Global,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemorySource {
    Confirmed,
    Inferred,
}

impl SemanticMemoryEntry {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        fingerprint_hash: impl Into<String>,
        asset_uri: impl Into<String>,
        region_alias: impl Into<String>,
        label: impl Into<String>,
        scope: MemoryScope,
        source: MemorySource,
        confidence: f32,
        updated_at: SwiftDate,
    ) -> Self {
        SemanticMemoryEntry {
            fingerprint_hash: fingerprint_hash.into(),
            asset_uri: asset_uri.into(),
            region_alias: region_alias.into(),
            label: label.into(),
            scope,
            source,
            confidence,
            updated_at,
        }
    }

    pub fn with_updated_at_now(
        fingerprint_hash: impl Into<String>,
        asset_uri: impl Into<String>,
        region_alias: impl Into<String>,
        label: impl Into<String>,
        scope: MemoryScope,
        source: MemorySource,
        confidence: f32,
    ) -> Self {
        SemanticMemoryEntry::new(
            fingerprint_hash,
            asset_uri,
            region_alias,
            label,
            scope,
            source,
            confidence,
            SwiftDate::now(),
        )
    }
}

/// Cross-session store that lets confirmed region labels survive asset re-imports.
/// Addressed by geometry fingerprint so topology-stable re-imports hit the cache automatically.
pub trait SemanticMemoryStore: Send + Sync {
    fn lookup(&self, fingerprint: &GeometryFingerprint) -> Vec<SemanticMemoryEntry>;

    fn record(
        &self,
        region_id: &str,
        fingerprint: &GeometryFingerprint,
        confirmation: &SemanticConfirmation,
    ) -> Result<(), SemanticMemoryError>;
}

/// In-memory implementation for tests and offline use.
pub struct EphemeralSemanticMemoryStore {
    entries: Mutex<BTreeMap<String, Vec<SemanticMemoryEntry>>>,
}

impl EphemeralSemanticMemoryStore {
    pub fn new() -> Self {
        EphemeralSemanticMemoryStore {
            entries: Mutex::new(BTreeMap::new()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Vec<SemanticMemoryEntry>>> {
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
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

impl Default for EphemeralSemanticMemoryStore {
    fn default() -> Self {
        EphemeralSemanticMemoryStore::new()
    }
}

impl SemanticMemoryStore for EphemeralSemanticMemoryStore {
    fn lookup(&self, fingerprint: &GeometryFingerprint) -> Vec<SemanticMemoryEntry> {
        let key = Self::hash_key(fingerprint);
        self.lock().get(&key).cloned().unwrap_or_default()
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
            "",
            region_id,
            label,
            MemoryScope::Asset,
            MemorySource::Confirmed,
            1.0,
            confirmation.confirmed_at,
        );
        self.lock().entry(key).or_default().push(entry);
        Ok(())
    }
}
