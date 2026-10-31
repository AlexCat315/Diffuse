//! `ObservationBus` — publish/subscribe with per-stream rings, cold log and
//! snapshot resync.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::cold_log::{ColdLog, ObservationBusError};
use crate::event_envelope::{
    EventEnvelope, EventOrigin, EventOriginProcessKind, EventPayloadRef, EventProvenance,
};
use crate::event_kind_registry::{EventKindId, EventKindRegistry, EventRetentionClass};

/// Cursor marking the position in a stream at which a snapshot was taken.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamCursor {
    pub stream_id: String,
    pub seq: u64,
}

impl StreamCursor {
    #[inline]
    pub fn new(stream_id: impl Into<String>, seq: u64) -> Self {
        StreamCursor {
            stream_id: stream_id.into(),
            seq,
        }
    }
}

/// A domain store implements this to support snapshot resync.
pub trait SnapshotProvider: Send {
    /// Capture the current domain state. Returns an opaque `snapshot_id` and the
    /// event cursor current when the snapshot was taken.
    fn materialize_snapshot(
        &self,
        scope: &str,
    ) -> Result<(String, StreamCursor), Box<dyn std::error::Error + Send + Sync>>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubscriptionDeliveryGuarantee {
    AtLeastOnce,
    BestEffort,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubscriptionAckMode {
    Auto,
    Manual,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubscriptionStartFrom {
    Latest,
    FromSeq { stream_id: String, seq: u64 },
    FromSnapshot { snapshot_id: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubscriptionBufferPolicy {
    DropOldest {
        size: usize,
    },
    DropNewest {
        size: usize,
    },
    Coalesce {
        size: usize,
        key_fields: Vec<String>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum EventFilter {
    All,
    KindIn(Vec<EventKindId>),
    StreamIn(Vec<String>),
    OriginProcessIn(Vec<EventOriginProcessKind>),
    ProvenanceIn(Vec<EventProvenance>),
    CausationIn(Vec<String>),
    And(Vec<EventFilter>),
    Or(Vec<EventFilter>),
    Not(Box<EventFilter>),
}

impl EventFilter {
    pub fn matches(&self, envelope: &EventEnvelope) -> bool {
        match self {
            EventFilter::All => true,
            EventFilter::KindIn(kinds) => kinds.contains(&envelope.kind),
            EventFilter::StreamIn(streams) => streams.contains(&envelope.stream_id),
            EventFilter::OriginProcessIn(processes) => processes.contains(&envelope.origin.process),
            EventFilter::ProvenanceIn(provenances) => provenances.contains(&envelope.provenance),
            EventFilter::CausationIn(ids) => envelope
                .causation_id
                .as_ref()
                .map(|value| ids.contains(value))
                .unwrap_or(false),
            EventFilter::And(filters) => filters.iter().all(|filter| filter.matches(envelope)),
            EventFilter::Or(filters) => filters.iter().any(|filter| filter.matches(envelope)),
            EventFilter::Not(filter) => !filter.matches(envelope),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SubscriptionSpec {
    pub id: String,
    pub filter: EventFilter,
    pub delivery: SubscriptionDeliveryGuarantee,
    pub start_from: SubscriptionStartFrom,
    pub buffer_policy: SubscriptionBufferPolicy,
    pub ack_mode: SubscriptionAckMode,
}

impl SubscriptionSpec {
    /// Swift defaults: allocated id, `.all`, best effort, latest, drop-oldest 64,
    /// auto-ack.
    pub fn new(id: String) -> Self {
        SubscriptionSpec {
            id,
            filter: EventFilter::All,
            delivery: SubscriptionDeliveryGuarantee::BestEffort,
            start_from: SubscriptionStartFrom::Latest,
            buffer_policy: SubscriptionBufferPolicy::DropOldest { size: 64 },
            ack_mode: SubscriptionAckMode::Auto,
        }
    }

    /// Mirrors Swift's default-argument initializer (the id is a fresh UUID).
    pub fn generate() -> Self {
        Self::new(new_uuid())
    }

    pub fn with_filter(mut self, filter: EventFilter) -> Self {
        self.filter = filter;
        self
    }

    pub fn with_delivery(mut self, delivery: SubscriptionDeliveryGuarantee) -> Self {
        self.delivery = delivery;
        self
    }

    pub fn with_start_from(mut self, start_from: SubscriptionStartFrom) -> Self {
        self.start_from = start_from;
        self
    }

    pub fn with_buffer_policy(mut self, buffer_policy: SubscriptionBufferPolicy) -> Self {
        self.buffer_policy = buffer_policy;
        self
    }

    pub fn with_ack_mode(mut self, ack_mode: SubscriptionAckMode) -> Self {
        self.ack_mode = ack_mode;
        self
    }
}

/// A random v4 UUID formatted exactly as Swift's `UUID().uuidString`: 36
/// characters, groups of 8-4-4-4-12. `diffuse-kernel::codable::new_uuid` is the
/// canonical implementation; keep this one byte-identical to it.
pub fn new_uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let time_low = (mixed & 0xFFFF_FFFF) as u32;
    let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
    let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
    let clock = ((counter & 0x3FFF) as u16) | 0x8000;
    let node: u64 = (mixed >> 8) & 0x0000_FFFF_FFFF_FFFF;
    format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node:012X}")
}

/// A subscription's buffered events.
pub struct ObservationSubscription {
    pub id: String,
    pub spec: SubscriptionSpec,
    queue: Mutex<Vec<EventEnvelope>>,
}

impl ObservationSubscription {
    fn new(spec: SubscriptionSpec, initial_events: Vec<EventEnvelope>) -> Self {
        let id = spec.id.clone();
        ObservationSubscription {
            id,
            spec,
            queue: Mutex::new(initial_events),
        }
    }

    fn lock_queue(&self) -> MutexGuard<'_, Vec<EventEnvelope>> {
        self.queue.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Returns the buffered events and clears them when ack mode is automatic.
    pub fn drain(&self) -> Vec<EventEnvelope> {
        let mut queue = self.lock_queue();
        let snapshot = queue.clone();
        if self.spec.ack_mode == SubscriptionAckMode::Auto {
            queue.clear();
        }
        snapshot
    }

    pub fn ack(&self, stream_id: &str, seq: u64) {
        let mut queue = self.lock_queue();
        queue.retain(|envelope| !(envelope.stream_id == stream_id && envelope.seq <= seq));
    }

    fn enqueue(&self, envelope: EventEnvelope) {
        let mut queue = self.lock_queue();
        match &self.spec.buffer_policy {
            SubscriptionBufferPolicy::DropOldest { size } => {
                Self::append_trimming_oldest(&mut queue, envelope, *size);
            }
            SubscriptionBufferPolicy::DropNewest { size } => {
                if queue.len() < (*size).max(1) {
                    queue.push(envelope);
                }
            }
            SubscriptionBufferPolicy::Coalesce { size, key_fields } => {
                let Some(new_key) = envelope.payload_ref.coalesce_key(key_fields) else {
                    Self::append_trimming_oldest(&mut queue, envelope, *size);
                    return;
                };
                if let Some(index) = queue.iter().rposition(|existing| {
                    existing.payload_ref.coalesce_key(key_fields).as_deref()
                        == Some(new_key.as_str())
                }) {
                    queue[index] = envelope;
                    return;
                }
                Self::append_trimming_oldest(&mut queue, envelope, *size);
            }
        }
    }

    fn append_trimming_oldest(
        queue: &mut Vec<EventEnvelope>,
        envelope: EventEnvelope,
        capacity: usize,
    ) {
        let limit = capacity.max(1);
        if queue.len() >= limit {
            let excess = queue.len() - limit + 1;
            queue.drain(0..excess);
        }
        queue.push(envelope);
    }
}

/// `ObservationBus`: per-stream sequence allocation, a bounded ring, optional cold
/// log, and subscriptions.
pub struct ObservationBus {
    pub registry: EventKindRegistry,
    ring_limit: usize,
    state: Mutex<BusState>,
    cold_log: Option<ColdLog>,
}

#[derive(Default)]
struct BusState {
    next_seq_by_stream: HashMap<String, u64>,
    events_by_stream: HashMap<String, Vec<EventEnvelope>>,
    subscriptions: HashMap<String, std::sync::Arc<ObservationSubscription>>,
    snapshot_providers: HashMap<String, Box<dyn SnapshotProvider + Send + Sync>>,
    snapshot_cursors: HashMap<String, StreamCursor>,
}

impl ObservationBus {
    /// Swift defaults: `.default` registry, no cold log, ring limit 256.
    pub fn new(
        registry: EventKindRegistry,
        cold_log_directory: Option<String>,
        ring_limit: usize,
    ) -> Result<Self, ObservationBusError> {
        let cold_log = match cold_log_directory {
            Some(directory) => Some(ColdLog::new(directory)?),
            None => None,
        };
        Ok(ObservationBus {
            registry,
            ring_limit: ring_limit.max(1),
            state: Mutex::new(BusState::default()),
            cold_log,
        })
    }

    pub fn with_defaults() -> Result<Self, ObservationBusError> {
        Self::new(EventKindRegistry::default_registry(), None, 256)
    }

    fn state(&self) -> MutexGuard<'_, BusState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    pub fn subscribe(&self, spec: SubscriptionSpec) -> std::sync::Arc<ObservationSubscription> {
        let mut state = self.state();
        let initial = Self::initial_events_locked(&state, &spec);
        let subscription = std::sync::Arc::new(ObservationSubscription::new(spec, initial));
        state
            .subscriptions
            .insert(subscription.id.clone(), subscription.clone());
        subscription
    }

    pub fn unsubscribe(&self, subscription_id: &str) {
        let mut state = self.state();
        state.subscriptions.remove(subscription_id);
    }

    pub fn register_snapshot_provider(
        &self,
        provider: Box<dyn SnapshotProvider + Send + Sync>,
        scope: &str,
    ) {
        let mut state = self.state();
        state.snapshot_providers.insert(scope.to_string(), provider);
    }

    /// Materializes a snapshot for `scope` and records its cursor so subscribers
    /// can start from `.FromSnapshot`.
    pub fn request_snapshot(
        &self,
        scope: &str,
    ) -> Result<(String, StreamCursor), ObservationBusError> {
        let provider_present = {
            let state = self.state();
            state.snapshot_providers.contains_key(scope)
        };
        if !provider_present {
            return Err(ObservationBusError::NoSnapshotProvider {
                scope: scope.to_string(),
            });
        }
        // The provider may publish into this bus, so it must run without the lock.
        let result = {
            let state = self.state();
            let provider = state.snapshot_providers.get(scope).ok_or_else(|| {
                ObservationBusError::NoSnapshotProvider {
                    scope: scope.to_string(),
                }
            })?;
            provider.materialize_snapshot(scope)
        };
        let (snapshot_id, cursor) =
            result.map_err(|error| ObservationBusError::ColdLogReadFailed(error.to_string()))?;
        {
            let mut state = self.state();
            state
                .snapshot_cursors
                .insert(snapshot_id.clone(), cursor.clone());
        }
        Ok((snapshot_id, cursor))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn publish(
        &self,
        kind: EventKindId,
        stream_id: &str,
        payload: EventPayloadRef,
        origin: EventOrigin,
        causal_seq: Option<u64>,
        causation_id: Option<String>,
        correlation_id: Option<String>,
        provenance: EventProvenance,
        schema_version: u32,
    ) -> Result<EventEnvelope, ObservationBusError> {
        let spec = self.registry.spec(kind).clone();
        // The bus lock guards sequence allocation and the stream ring only, matching
        // the Swift comment: filter matching runs outside it.
        let (published, candidates) = {
            let mut state = self.state();
            let next_seq = state
                .next_seq_by_stream
                .get(stream_id)
                .copied()
                .unwrap_or(0)
                + 1;
            state
                .next_seq_by_stream
                .insert(stream_id.to_string(), next_seq);
            let envelope = EventEnvelope::new(
                format!("{stream_id}#{next_seq}"),
                kind,
                stream_id,
                next_seq,
                causal_seq,
                monotonic_timestamp_ns(),
                wall_timestamp_utc_ms(),
                origin,
                causation_id,
                correlation_id,
                provenance,
                payload,
                schema_version,
                false,
            );
            let ring_limit = self.ring_limit;
            let stream_events = state
                .events_by_stream
                .entry(stream_id.to_string())
                .or_default();
            stream_events.push(envelope.clone());
            if stream_events.len() > ring_limit {
                let excess = stream_events.len() - ring_limit;
                stream_events.drain(0..excess);
            }
            let candidates: Vec<std::sync::Arc<ObservationSubscription>> =
                state.subscriptions.values().cloned().collect();
            (envelope, candidates)
        };

        if spec.replayable
            && spec.retention != EventRetentionClass::Ephemeral
            && let Some(cold_log) = &self.cold_log
        {
            cold_log.append(&published)?;
        }
        for subscription in candidates {
            if subscription.spec.filter.matches(&published) {
                subscription.enqueue(published.clone());
            }
        }
        Ok(published)
    }

    pub fn publish_draft(&self, draft: &EventDraft) -> Result<EventEnvelope, ObservationBusError> {
        self.publish(
            draft.kind,
            &draft.stream_id,
            draft.payload_ref.clone(),
            draft.origin.clone(),
            draft.causal_seq,
            draft.causation_id.clone(),
            draft.correlation_id.clone(),
            draft.provenance,
            draft.schema_version,
        )
    }

    pub fn publish_batch(
        &self,
        drafts: &[EventDraft],
    ) -> Result<Vec<EventEnvelope>, ObservationBusError> {
        drafts
            .iter()
            .map(|draft| self.publish_draft(draft))
            .collect()
    }

    pub fn events(&self, stream_id: &str) -> Vec<EventEnvelope> {
        let state = self.state();
        state
            .events_by_stream
            .get(stream_id)
            .cloned()
            .unwrap_or_default()
    }

    pub fn replay(
        &self,
        stream_id: &str,
        from_seq: u64,
        to_seq: Option<u64>,
    ) -> Result<Vec<EventEnvelope>, ObservationBusError> {
        if let Some(cold_log) = &self.cold_log {
            let envelopes = cold_log.read(stream_id, from_seq, to_seq)?;
            return Ok(envelopes
                .into_iter()
                .map(|mut envelope| {
                    envelope.replay = true;
                    envelope
                })
                .collect());
        }
        let upper_bound = to_seq.unwrap_or(u64::MAX);
        Ok(self
            .events(stream_id)
            .into_iter()
            .filter(|envelope| envelope.seq >= from_seq && envelope.seq <= upper_bound)
            .map(|mut envelope| {
                envelope.replay = true;
                envelope
            })
            .collect())
    }

    fn initial_events_locked(state: &BusState, spec: &SubscriptionSpec) -> Vec<EventEnvelope> {
        match &spec.start_from {
            SubscriptionStartFrom::Latest => Vec::new(),
            SubscriptionStartFrom::FromSeq { stream_id, seq } => state
                .events_by_stream
                .get(stream_id)
                .map(|events| {
                    events
                        .iter()
                        .filter(|envelope| envelope.seq > *seq && spec.filter.matches(envelope))
                        .cloned()
                        .collect()
                })
                .unwrap_or_default(),
            SubscriptionStartFrom::FromSnapshot { snapshot_id } => {
                let Some(cursor) = state.snapshot_cursors.get(snapshot_id) else {
                    return Vec::new();
                };
                state
                    .events_by_stream
                    .get(&cursor.stream_id)
                    .map(|events| {
                        events
                            .iter()
                            .filter(|envelope| {
                                envelope.seq > cursor.seq && spec.filter.matches(envelope)
                            })
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default()
            }
        }
    }
}

/// `DispatchTime.now().uptimeNanoseconds`.
pub fn monotonic_timestamp_ns() -> u64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(std::time::Instant::now);
    start.elapsed().as_nanos() as u64
}

/// `Int64(Date().timeIntervalSince1970 * 1000)`.
pub fn wall_timestamp_utc_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

/// A queued draft waiting for `OutboxRelay` to flush it.
#[derive(Clone, Debug, PartialEq)]
pub struct EventDraft {
    pub kind: EventKindId,
    pub stream_id: String,
    pub causal_seq: Option<u64>,
    pub origin: EventOrigin,
    pub causation_id: Option<String>,
    pub correlation_id: Option<String>,
    pub provenance: EventProvenance,
    pub payload_ref: EventPayloadRef,
    pub schema_version: u32,
}

impl EventDraft {
    /// Swift defaults: `causalSeq`/`causationID`/`correlationID` nil,
    /// `schemaVersion` 1.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        kind: EventKindId,
        stream_id: impl Into<String>,
        origin: EventOrigin,
        provenance: EventProvenance,
        payload_ref: EventPayloadRef,
    ) -> Self {
        EventDraft {
            kind,
            stream_id: stream_id.into(),
            causal_seq: None,
            origin,
            causation_id: None,
            correlation_id: None,
            provenance,
            payload_ref,
            schema_version: 1,
        }
    }
}

#[cfg(test)]
mod uuid_shape_tests {
    use super::new_uuid;

    /// Swift's `UUID().uuidString` is 36 characters, groups 8-4-4-4-12. A previous
    /// version of this function produced 34 characters because the node was
    /// formatted as two short fields.
    #[test]
    fn uuid_is_thirty_six_characters_with_five_groups() {
        for _ in 0..256 {
            let value = new_uuid();
            assert_eq!(value.len(), 36, "wrong length: {value}");
            let groups: Vec<usize> = value.split('-').map(str::len).collect();
            assert_eq!(groups, vec![8, 4, 4, 4, 12], "wrong grouping: {value}");
            assert_eq!(value, value.to_uppercase());
        }
    }
}
