//! `ObservationBusTests` — Swift suite `ObservationBus`.

use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use diffuse_observation::cold_log::ObservationBusError;
use diffuse_observation::event_envelope::{
    EventOrigin, EventOriginProcessKind, EventPayloadHandle, EventPayloadRecord, EventPayloadRef,
    EventProvenance, EventValue,
};
use diffuse_observation::event_kind_registry::EventKindId;
use diffuse_observation::publisher::{
    EventFilter, ObservationBus, SnapshotProvider, StreamCursor, SubscriptionBufferPolicy,
    SubscriptionSpec, SubscriptionStartFrom,
};

fn inline(entries: &[(&str, EventValue)]) -> EventPayloadRef {
    let mut record = EventPayloadRecord::new();
    for (key, value) in entries {
        record.insert((*key).to_string(), value.clone());
    }
    EventPayloadRef::inline(record)
}

fn tool_origin() -> EventOrigin {
    EventOrigin::new(EventOriginProcessKind::Tool, "test-host", None, None)
}

fn publish(
    bus: &ObservationBus,
    kind: EventKindId,
    stream_id: &str,
    payload: EventPayloadRef,
    provenance: EventProvenance,
) -> diffuse_observation::event_envelope::EventEnvelope {
    bus.publish(
        kind,
        stream_id,
        payload,
        tool_origin(),
        None,
        None,
        None,
        provenance,
        1,
    )
    .expect("publish must succeed")
}

// "publish writes envelopes into subscriptions and cold log replay"
#[test]
fn publish_writes_into_subscriptions_and_cold_log() {
    let root = std::env::temp_dir().join(uuid_like());
    std::fs::create_dir_all(&root).expect("temp dir");

    let bus = ObservationBus::new(
        diffuse_observation::event_kind_registry::EventKindRegistry::default_registry(),
        Some(root.to_string_lossy().to_string()),
        256,
    )
    .expect("bus");

    let subscription = bus.subscribe(
        SubscriptionSpec::generate()
            .with_filter(EventFilter::KindIn(vec![EventKindId::TransactionApplied]))
            .with_start_from(SubscriptionStartFrom::Latest)
            .with_buffer_policy(SubscriptionBufferPolicy::DropOldest { size: 4 }),
    );

    let envelope = publish(
        &bus,
        EventKindId::TransactionApplied,
        "transaction",
        inline(&[
            ("transaction_id", EventValue::String("tx.001".into())),
            ("status", EventValue::String("applied".into())),
        ]),
        EventProvenance::Authored,
    );

    let delivered = subscription.drain();
    let replayed = bus.replay("transaction", 1, None).expect("replay");

    assert_eq!(
        delivered
            .iter()
            .map(|value| value.event_id.clone())
            .collect::<Vec<_>>(),
        vec![envelope.event_id.clone()]
    );
    assert_eq!(
        replayed
            .iter()
            .map(|value| value.event_id.clone())
            .collect::<Vec<_>>(),
        vec![envelope.event_id.clone()]
    );
    assert!(replayed.iter().all(|value| value.replay));

    let _ = std::fs::remove_dir_all(&root);
}

// "coalesce buffer keeps the latest scene change for the same entity key"
#[test]
fn coalesce_buffer_keeps_latest_scene_change() {
    let bus = ObservationBus::new(
        diffuse_observation::event_kind_registry::EventKindRegistry::default_registry(),
        None,
        8,
    )
    .expect("bus");

    let subscription = bus.subscribe(
        SubscriptionSpec::generate()
            .with_filter(EventFilter::KindIn(vec![EventKindId::SceneChanged]))
            .with_start_from(SubscriptionStartFrom::Latest)
            .with_buffer_policy(SubscriptionBufferPolicy::Coalesce {
                size: 4,
                key_fields: vec!["entity_id".to_string()],
            }),
    );

    publish(
        &bus,
        EventKindId::SceneChanged,
        "scene:test",
        inline(&[
            ("entity_id", EventValue::Integer(42)),
            ("scene_revision", EventValue::Integer(1)),
        ]),
        EventProvenance::Authored,
    );
    publish(
        &bus,
        EventKindId::SceneChanged,
        "scene:test",
        inline(&[
            ("entity_id", EventValue::Integer(42)),
            ("scene_revision", EventValue::Integer(2)),
        ]),
        EventProvenance::Authored,
    );

    let delivered = subscription.drain();

    assert_eq!(delivered.len(), 1);
    assert_eq!(
        delivered[0]
            .payload_ref
            .inline_record()
            .and_then(|record| record.get("scene_revision")),
        Some(&EventValue::Integer(2))
    );
}

// "SubscriberToken cancellation removes the subscription from the bus"
#[test]
fn subscriber_token_cancellation_removes_subscription() {
    let bus = Arc::new(ObservationBus::with_defaults().expect("bus"));
    let token = bus.sink(
        SubscriptionSpec::generate()
            .with_filter(EventFilter::KindIn(vec![EventKindId::SceneChanged])),
        Duration::from_secs(60),
        |_| {},
    );
    let id = token.subscription_id.clone();
    assert!(!token.is_cancelled());

    token.cancel();
    assert!(token.is_cancelled());

    // Re-subscribing with the same id must still receive events.
    let second = bus.subscribe(
        SubscriptionSpec::new(id).with_filter(EventFilter::KindIn(vec![EventKindId::SceneChanged])),
    );
    publish(
        &bus,
        EventKindId::SceneChanged,
        "scene:test",
        inline(&[
            ("entity_id", EventValue::Integer(1)),
            ("scene_revision", EventValue::Integer(1)),
        ]),
        EventProvenance::Authored,
    );
    assert_eq!(second.drain().len(), 1);
}

// "sink delivers events to handler on background queue"
#[test]
fn sink_delivers_events_to_handler() {
    let bus = Arc::new(ObservationBus::with_defaults().expect("bus"));
    let received: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let (sender, receiver) = mpsc::channel();

    let received_for_handler = received.clone();
    let token = bus.sink(
        SubscriptionSpec::generate()
            .with_filter(EventFilter::KindIn(vec![EventKindId::TransactionApplied])),
        Duration::from_millis(10),
        move |envelopes| {
            if let Ok(mut ids) = received_for_handler.lock() {
                for envelope in envelopes {
                    ids.push(envelope.event_id);
                }
            }
            let _ = sender.send(());
        },
    );

    let envelope = publish(
        &bus,
        EventKindId::TransactionApplied,
        "transaction",
        inline(&[
            ("transaction_id", EventValue::String("tx.sink".into())),
            ("status", EventValue::String("applied".into())),
        ]),
        EventProvenance::Authored,
    );

    let result = receiver.recv_timeout(Duration::from_secs(2));
    assert!(result.is_ok());

    let ids = received.lock().expect("ids").clone();
    assert!(ids.contains(&envelope.event_id));
    token.cancel();
}

// "events() AsyncStream yields published envelopes"
#[test]
fn events_stream_yields_published_envelopes() {
    let bus = Arc::new(ObservationBus::with_defaults().expect("bus"));
    let (token, receiver) = bus.events_stream(
        SubscriptionSpec::generate()
            .with_filter(EventFilter::KindIn(vec![EventKindId::SceneEntityAdded])),
        Duration::from_millis(10),
    );

    let envelope = publish(
        &bus,
        EventKindId::SceneEntityAdded,
        "scene:main",
        inline(&[
            (
                "entity_ids",
                EventValue::Array(vec![EventValue::Integer(99)]),
            ),
            ("scene_revision", EventValue::Integer(1)),
        ]),
        EventProvenance::Authored,
    );

    let received = receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("event");
    assert_eq!(received.event_id, envelope.event_id);
    token.cancel();
}

// "symbolicView excludes redact_in_prompt and runtime tick events"
#[test]
fn symbolic_view_excludes_redacted_and_tick_events() {
    let bus = ObservationBus::with_defaults().expect("bus");

    publish(
        &bus,
        EventKindId::RuntimeTick,
        "runtime",
        inline(&[("frame", EventValue::Integer(1))]),
        EventProvenance::Runtime,
    );
    publish(
        &bus,
        EventKindId::TransactionApplied,
        "runtime",
        inline(&[
            ("transaction_id", EventValue::String("tx.1".into())),
            ("status", EventValue::String("applied".into())),
        ]),
        EventProvenance::Authored,
    );

    let view = bus.symbolic_view("runtime", 0, 50);
    assert_eq!(view.events.len(), 1);
    assert_eq!(view.events[0].kind, EventKindId::TransactionApplied);
}

// "symbolicView compacts inline payload fields to strings"
#[test]
fn symbolic_view_compacts_inline_payload() {
    let bus = ObservationBus::with_defaults().expect("bus");
    publish(
        &bus,
        EventKindId::TransactionApplied,
        "scene:main",
        inline(&[
            ("transaction_id", EventValue::String("tx.42".into())),
            ("status", EventValue::String("applied".into())),
            ("count", EventValue::Integer(7)),
        ]),
        EventProvenance::Authored,
    );

    let view = bus.symbolic_view("scene:main", 0, 50);
    assert_eq!(view.events.len(), 1);
    let event = &view.events[0];
    assert_eq!(
        event.summary.get("transaction_id"),
        Some(&"tx.42".to_string())
    );
    assert_eq!(event.summary.get("count"), Some(&"7".to_string()));
}

// "symbolicView handle payload yields existence marker"
#[test]
fn symbolic_view_handle_payload_yields_marker() {
    let bus = ObservationBus::with_defaults().expect("bus");
    publish(
        &bus,
        EventKindId::AssetImportFinished,
        "asset",
        EventPayloadRef::Handle(EventPayloadHandle::new("artifacts", "abc123", "sha256:0")),
        EventProvenance::Inferred,
    );

    let view = bus.symbolic_view("asset", 0, 50);
    assert_eq!(view.events.len(), 1);
    assert_eq!(
        view.events[0].summary.get("payload"),
        Some(&"<handle:artifacts/abc123>".to_string())
    );
}

// "symbolicView promptText renders compact multi-line string"
#[test]
fn symbolic_view_prompt_text() {
    let bus = ObservationBus::with_defaults().expect("bus");
    publish(
        &bus,
        EventKindId::SceneEntityAdded,
        "scene:main",
        inline(&[
            (
                "entity_ids",
                EventValue::Array(vec![EventValue::Integer(1)]),
            ),
            ("scene_revision", EventValue::Integer(5)),
        ]),
        EventProvenance::Authored,
    );

    let text = bus.symbolic_view("scene:main", 0, 50).prompt_text();
    assert!(text.contains("scene.entity.added"));
    assert!(text.contains("scene:main"));
}

// "symbolicView maxCount caps output"
#[test]
fn symbolic_view_max_count_caps() {
    let bus = ObservationBus::with_defaults().expect("bus");
    for index in 1..=10 {
        publish(
            &bus,
            EventKindId::TransactionApplied,
            "tx",
            inline(&[
                ("transaction_id", EventValue::String(format!("tx.{index}"))),
                ("status", EventValue::String("applied".into())),
            ]),
            EventProvenance::Authored,
        );
    }

    let view = bus.symbolic_view("tx", 0, 3);
    assert_eq!(view.events.len(), 3);
    assert_eq!(
        view.events[0].summary.get("transaction_id"),
        Some(&"tx.8".to_string())
    );
}

// MARK: - Snapshot resync

struct StaticSnapshotProvider {
    snapshot_id: String,
    cursor: StreamCursor,
}

impl SnapshotProvider for StaticSnapshotProvider {
    fn materialize_snapshot(
        &self,
        _scope: &str,
    ) -> Result<(String, StreamCursor), Box<dyn std::error::Error + Send + Sync>> {
        Ok((self.snapshot_id.clone(), self.cursor.clone()))
    }
}

// "requestSnapshot throws noSnapshotProvider when no provider is registered"
#[test]
fn request_snapshot_throws_when_no_provider() {
    let bus = ObservationBus::with_defaults().expect("bus");
    let result = bus.request_snapshot("scene");
    assert_eq!(
        result.map(|_| ()),
        Err(ObservationBusError::NoSnapshotProvider {
            scope: "scene".to_string()
        })
    );
}

// "fromSnapshot subscriber receives events published after the snapshot cursor"
#[test]
fn from_snapshot_delivers_events_after_cursor() {
    let bus = ObservationBus::with_defaults().expect("bus");

    let pre1 = publish(
        &bus,
        EventKindId::SceneChanged,
        "scene:main",
        inline(&[
            ("entity_id", EventValue::String("e1".into())),
            ("change_type", EventValue::String("added".into())),
        ]),
        EventProvenance::Authored,
    );
    publish(
        &bus,
        EventKindId::SceneChanged,
        "scene:main",
        inline(&[
            ("entity_id", EventValue::String("e2".into())),
            ("change_type", EventValue::String("added".into())),
        ]),
        EventProvenance::Authored,
    );

    let cursor = StreamCursor::new("scene:main", pre1.seq + 1);
    bus.register_snapshot_provider(
        Box::new(StaticSnapshotProvider {
            snapshot_id: "snap-1".to_string(),
            cursor: cursor.clone(),
        }),
        "scene",
    );

    let (snapshot_id, returned_cursor) = bus.request_snapshot("scene").expect("snapshot");
    assert_eq!(snapshot_id, "snap-1");
    assert_eq!(returned_cursor, cursor);

    publish(
        &bus,
        EventKindId::SceneChanged,
        "scene:main",
        inline(&[
            ("entity_id", EventValue::String("e3".into())),
            ("change_type", EventValue::String("added".into())),
        ]),
        EventProvenance::Authored,
    );

    let subscription = bus.subscribe(
        SubscriptionSpec::generate()
            .with_start_from(SubscriptionStartFrom::FromSnapshot { snapshot_id }),
    );
    let events = subscription.drain();
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0]
            .payload_ref
            .inline_record()
            .and_then(|record| record.get("entity_id")),
        Some(&EventValue::String("e3".into()))
    );
}

/// Mirrors Swift's `UUID().uuidString` for a throwaway temp directory name.
fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);
    format!("diffuse-observation-{nanos}")
}
