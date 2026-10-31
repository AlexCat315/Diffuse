//! One domain's enabled declarations. Readers receive an immutable snapshot.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Catalog.swift`.
//!
//! Swift's `NSLock` around a dictionary maps to a `Mutex`; the generic value
//! parameter covers every contribution family without `Any`.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::lifecycle::status::PluginManagerError;
use crate::uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributedValue<Value> {
    pub plugin_id: String,
    pub value: Value,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributionSnapshot<Value> {
    pub revision: u64,
    pub values: Vec<ContributedValue<Value>>,
}

struct Entry<Value> {
    generation: Uuid,
    values: Vec<Value>,
}

struct State<Value> {
    entries: BTreeMap<String, Entry<Value>>,
    revision: u64,
}

pub struct ContributionCatalog<Value> {
    state: Mutex<State<Value>>,
}

impl<Value: Clone + Send + 'static> ContributionCatalog<Value> {
    pub fn new() -> Self {
        ContributionCatalog {
            state: Mutex::new(State {
                entries: BTreeMap::new(),
                revision: 0,
            }),
        }
    }

    /// Registers one plugin's values. The handle releases them only if this
    /// generation is still the one registered, so a later re-register is not
    /// torn down by an earlier handle.
    pub fn register(
        self: &Arc<Self>,
        values: Vec<Value>,
        plugin_id: &str,
    ) -> Result<Arc<crate::lifecycle::disposal::Registration>, PluginManagerError> {
        let generation = Uuid::new();
        {
            let mut state = self.lock();
            if state.entries.contains_key(plugin_id) {
                return Err(PluginManagerError::AlreadyEnabled(plugin_id.to_string()));
            }
            state.entries.insert(
                plugin_id.to_string(),
                Entry {
                    generation: generation.clone(),
                    values,
                },
            );
            // Swift used `&+=`; release builds keep overflow checks on
            // (MIGRATION.md §2.2), so the wrapping form is explicit.
            state.revision = state.revision.wrapping_add(1);
        }
        let catalog = Arc::downgrade(self);
        let plugin_id = plugin_id.to_string();
        Ok(Arc::new(crate::lifecycle::disposal::Registration::new(
            move || {
                let Some(catalog) = catalog.upgrade() else {
                    return;
                };
                let mut state = catalog.lock();
                let matches = state
                    .entries
                    .get(&plugin_id)
                    .is_some_and(|entry| entry.generation == generation);
                if !matches {
                    return;
                }
                state.entries.remove(&plugin_id);
                state.revision = state.revision.wrapping_add(1);
            },
        )))
    }

    pub fn snapshot(&self) -> ContributionSnapshot<Value> {
        let state = self.lock();
        // `entries.keys.sorted()` — the `BTreeMap` is already in that order.
        let values = state
            .entries
            .iter()
            .flat_map(|(id, entry)| {
                entry
                    .values
                    .iter()
                    .map(|value| ContributedValue {
                        plugin_id: id.clone(),
                        value: value.clone(),
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        ContributionSnapshot {
            revision: state.revision,
            values,
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State<Value>> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }
}

impl<Value: Clone + Send + 'static> Default for ContributionCatalog<Value> {
    fn default() -> Self {
        Self::new()
    }
}
