//! Local semantic state shared by AI providers and local perception workers.
//!
//! Keeps Cove's AI-visible world available even when no remote text provider is
//! configured. Remote `Session` instances can be seeded from it.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use diffuse_intent::transactions::world_event::WorldEvent;
use diffuse_kernel::codable::new_uuid;
use diffuse_observation::publisher::{SnapshotProvider, StreamCursor};

use crate::context::world_view::{WorldEntityRecord, WorldView};
use crate::semantic::scene_semantic_snapshot::SceneSemanticSnapshot;

pub struct AIWorldContext {
    state: Mutex<AIWorldContextState>,
}

struct AIWorldContextState {
    world_view: WorldView,
    world_revision: u64,
    stored_snapshots: HashMap<String, WorldView>,
    snapshot_insertion_order: Vec<String>,
}

impl AIWorldContext {
    const MAX_STORED_SNAPSHOTS: usize = 8;

    pub fn new(world_view: WorldView) -> Self {
        Self {
            state: Mutex::new(AIWorldContextState {
                world_view,
                world_revision: 0,
                stored_snapshots: HashMap::new(),
                snapshot_insertion_order: Vec::new(),
            }),
        }
    }

    fn lock_state(&self) -> MutexGuard<'_, AIWorldContextState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn observe_snapshot(&self, snapshot: SceneSemanticSnapshot) {
        let mut state = self.lock_state();
        state.world_view.apply_snapshot(&snapshot);
        state.world_revision += 1;
    }

    pub fn observe_event(&self, event: WorldEvent) {
        let mut state = self.lock_state();
        state.world_view.apply_event(event);
        state.world_revision += 1;
    }

    pub fn observe_events(&self, events: Vec<WorldEvent>) {
        let mut state = self.lock_state();
        let count = events.len() as u64;
        for event in events {
            state.world_view.apply_event(event);
        }
        if count > 0 {
            state.world_revision += count;
        }
    }

    pub fn replace_world_view(&self, world_view: WorldView) {
        let mut state = self.lock_state();
        state.world_view = world_view;
        state.world_revision += 1;
    }

    pub fn snapshot(&self) -> WorldView {
        self.lock_state().world_view.clone()
    }

    pub fn entity_record(&self, ref_: &str) -> Option<WorldEntityRecord> {
        self.lock_state().world_view.entity_record(ref_).cloned()
    }

    /// Returns the `WorldView` captured for `snapshot_id`, or `None` if it was
    /// never materialized or has been evicted.
    pub fn world_view_for_snapshot(&self, snapshot_id: &str) -> Option<WorldView> {
        self.lock_state().stored_snapshots.get(snapshot_id).cloned()
    }

    pub fn discard_snapshot(&self, snapshot_id: &str) {
        let mut state = self.lock_state();
        state.stored_snapshots.remove(snapshot_id);
        state
            .snapshot_insertion_order
            .retain(|stored| stored != snapshot_id);
    }
}

impl Default for AIWorldContext {
    fn default() -> Self {
        Self::new(WorldView::new())
    }
}

// MARK: - SnapshotProvider

impl SnapshotProvider for AIWorldContext {
    /// Captures the current `WorldView` under a fresh UUID, returning that ID and
    /// a cursor pointing to the current world revision on the "world" stream.
    ///
    /// Callers can retrieve the captured `WorldView` with
    /// `world_view_for_snapshot`. Subscribers using `.fromSnapshot(snapshotID:)`
    /// will receive any ObservationBus events on the "world" stream published
    /// after this point.
    fn materialize_snapshot(
        &self,
        _scope: &str,
    ) -> Result<(String, StreamCursor), Box<dyn std::error::Error + Send + Sync>> {
        let snapshot_id = new_uuid();
        let mut state = self.lock_state();
        // Evict oldest entries to cap memory usage (FIFO by insertion order).
        while state.stored_snapshots.len() >= Self::MAX_STORED_SNAPSHOTS {
            let Some(oldest) = state.snapshot_insertion_order.first().cloned() else {
                break;
            };
            state.snapshot_insertion_order.remove(0);
            state.stored_snapshots.remove(&oldest);
        }
        let world_view = state.world_view.clone();
        state
            .stored_snapshots
            .insert(snapshot_id.clone(), world_view);
        state.snapshot_insertion_order.push(snapshot_id.clone());
        let cursor = StreamCursor::new("world", state.world_revision);
        Ok((snapshot_id, cursor))
    }
}
