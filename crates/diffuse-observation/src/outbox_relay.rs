//! `OutboxRelay` — queues event drafts and flushes them into the bus in order.

use std::sync::{Arc, Mutex};

use crate::cold_log::ObservationBusError;
use crate::event_envelope::EventEnvelope;
use crate::publisher::{EventDraft, ObservationBus};

pub struct OutboxRelay {
    drafts: Mutex<Vec<EventDraft>>,
}

impl OutboxRelay {
    #[inline]
    pub fn new() -> Self {
        OutboxRelay {
            drafts: Mutex::new(Vec::new()),
        }
    }

    pub fn enqueue(&self, draft: EventDraft) {
        let mut drafts = self
            .drafts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        drafts.push(draft);
    }

    pub fn pending_count(&self) -> usize {
        let drafts = self
            .drafts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        drafts.len()
    }

    /// Publishes every queued draft and clears the queue.
    pub fn flush(&self, bus: &ObservationBus) -> Result<Vec<EventEnvelope>, ObservationBusError> {
        let snapshot = {
            let drafts = self
                .drafts
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            drafts.clone()
        };
        let published = bus.publish_batch(&snapshot)?;
        let mut drafts = self
            .drafts
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        drafts.clear();
        Ok(published)
    }

    /// Shared-relay convenience matching Swift's reference semantics.
    pub fn flush_shared(
        relay: &Arc<OutboxRelay>,
        bus: &ObservationBus,
    ) -> Result<Vec<EventEnvelope>, ObservationBusError> {
        relay.flush(bus)
    }
}

impl Default for OutboxRelay {
    fn default() -> Self {
        Self::new()
    }
}
