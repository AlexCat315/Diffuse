//! `EventKindRegistry` and the event vocabulary it indexes.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventDomain {
    Project,
    Scene,
    Sequence,
    Model,
    Asset,
    Transaction,
    Diagnostics,
    Ui,
    Runtime,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventPayloadSchemaId {
    #[serde(rename = "transaction_lifecycle")]
    TransactionLifecycle,
    #[serde(rename = "scene_changed")]
    SceneChanged,
    #[serde(rename = "scene_entity_changed")]
    SceneEntityChanged,
    #[serde(rename = "sequence_changed")]
    SequenceChanged,
    #[serde(rename = "asset_import_finished")]
    AssetImportFinished,
    #[serde(rename = "diagnostics_warning_raised")]
    DiagnosticsWarningRaised,
    #[serde(rename = "selection_changed")]
    SelectionChanged,
    #[serde(rename = "confirmation_requested")]
    ConfirmationRequested,
    #[serde(rename = "confirmation_resolved")]
    ConfirmationResolved,
    #[serde(rename = "runtime_tick")]
    RuntimeTick,
    #[serde(rename = "runtime_metric_sampled")]
    RuntimeMetricSampled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventCardinality {
    #[serde(rename = "per_tick")]
    PerTick,
    #[serde(rename = "per_change")]
    PerChange,
    #[serde(rename = "per_batch")]
    PerBatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventOrdering {
    #[serde(rename = "per_aggregate")]
    PerAggregate,
    #[serde(rename = "per_stream")]
    PerStream,
    None,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventRetentionClass {
    Hot,
    Warm,
    Cold,
    Ephemeral,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventCoalesceReducer {
    #[serde(rename = "keep_last")]
    KeepLast,
    #[serde(rename = "merge_set")]
    MergeSet,
    Sum,
    #[serde(rename = "union_diff")]
    UnionDiff,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventCoalesceHint {
    pub key_fields: Vec<String>,
    pub reducer: EventCoalesceReducer,
}

impl EventCoalesceHint {
    #[inline]
    pub fn new(key_fields: Vec<String>, reducer: EventCoalesceReducer) -> Self {
        EventCoalesceHint {
            key_fields,
            reducer,
        }
    }

    /// Convenience for the `[&str; N]` initializers used by the default specs.
    pub fn from_keys(keys: &[&str], reducer: EventCoalesceReducer) -> Self {
        EventCoalesceHint {
            key_fields: keys.iter().map(|key| key.to_string()).collect(),
            reducer,
        }
    }
}

/// Swift's `EventKindID`, encoded as its dotted raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EventKindId {
    SceneChanged,
    SceneEntityAdded,
    SceneEntityRemoved,
    SequenceChanged,
    AssetImportFinished,
    TransactionStaged,
    TransactionApplied,
    TransactionDiscarded,
    TransactionFailed,
    DiagnosticsWarningRaised,
    SelectionChanged,
    ConfirmationRequested,
    ConfirmationResolved,
    RuntimeTick,
    RuntimeMetricSampled,
}

impl EventKindId {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EventKindId; 15] = [
        EventKindId::SceneChanged,
        EventKindId::SceneEntityAdded,
        EventKindId::SceneEntityRemoved,
        EventKindId::SequenceChanged,
        EventKindId::AssetImportFinished,
        EventKindId::TransactionStaged,
        EventKindId::TransactionApplied,
        EventKindId::TransactionDiscarded,
        EventKindId::TransactionFailed,
        EventKindId::DiagnosticsWarningRaised,
        EventKindId::SelectionChanged,
        EventKindId::ConfirmationRequested,
        EventKindId::ConfirmationResolved,
        EventKindId::RuntimeTick,
        EventKindId::RuntimeMetricSampled,
    ];

    /// `rawValue`.
    pub const fn raw_value(self) -> &'static str {
        match self {
            EventKindId::SceneChanged => "scene.changed",
            EventKindId::SceneEntityAdded => "scene.entity.added",
            EventKindId::SceneEntityRemoved => "scene.entity.removed",
            EventKindId::SequenceChanged => "sequence.changed",
            EventKindId::AssetImportFinished => "asset.import.finished",
            EventKindId::TransactionStaged => "transaction.staged",
            EventKindId::TransactionApplied => "transaction.applied",
            EventKindId::TransactionDiscarded => "transaction.discarded",
            EventKindId::TransactionFailed => "transaction.failed",
            EventKindId::DiagnosticsWarningRaised => "diagnostics.warning.raised",
            EventKindId::SelectionChanged => "selection.changed",
            EventKindId::ConfirmationRequested => "ui.confirmation.requested",
            EventKindId::ConfirmationResolved => "ui.confirmation.resolved",
            EventKindId::RuntimeTick => "runtime.tick",
            EventKindId::RuntimeMetricSampled => "runtime.metric.sampled",
        }
    }

    /// Swift's `RawRepresentable` initializer.
    pub fn from_raw_value(value: &str) -> Option<EventKindId> {
        EventKindId::ALL
            .into_iter()
            .find(|kind| kind.raw_value() == value)
    }
}

impl Serialize for EventKindId {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for EventKindId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<EventKindId, D::Error> {
        let value = String::deserialize(deserializer)?;
        EventKindId::from_raw_value(&value)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown EventKindID '{value}'")))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventKindSpec {
    pub id: EventKindId,
    pub domain: EventDomain,
    pub payload_schema: EventPayloadSchemaId,
    pub cardinality: EventCardinality,
    pub ordering: EventOrdering,
    pub redact_in_prompt: bool,
    pub retention: EventRetentionClass,
    pub replayable: bool,
    pub cross_process_allowed: bool,
    pub coalesce_hint: Option<EventCoalesceHint>,
    pub added_in: String,
    pub deprecated_in: Option<String>,
}

impl EventKindSpec {
    #[allow(clippy::too_many_arguments)]
    #[inline]
    pub fn new(
        id: EventKindId,
        domain: EventDomain,
        payload_schema: EventPayloadSchemaId,
        cardinality: EventCardinality,
        ordering: EventOrdering,
        redact_in_prompt: bool,
        retention: EventRetentionClass,
        replayable: bool,
        cross_process_allowed: bool,
        coalesce_hint: Option<EventCoalesceHint>,
        added_in: String,
        deprecated_in: Option<String>,
    ) -> Self {
        EventKindSpec {
            id,
            domain,
            payload_schema,
            cardinality,
            ordering,
            redact_in_prompt,
            retention,
            replayable,
            cross_process_allowed,
            coalesce_hint,
            added_in,
            deprecated_in,
        }
    }
}

#[derive(Clone, Debug)]
pub struct EventKindRegistry {
    specs: BTreeMap<EventKindId, EventKindSpec>,
}

impl EventKindRegistry {
    #[inline]
    pub fn new(specs: BTreeMap<EventKindId, EventKindSpec>) -> Self {
        EventKindRegistry { specs }
    }

    /// Swift used `preconditionFailure` here; Rust panics with the same message.
    pub fn spec(&self, kind: EventKindId) -> &EventKindSpec {
        match self.specs.get(&kind) {
            Some(spec) => spec,
            None => panic!("missing EventKindSpec for {}", kind.raw_value()),
        }
    }

    #[inline]
    pub fn contains(&self, kind: EventKindId) -> bool {
        self.specs.contains_key(&kind)
    }

    /// Swift's `EventKindRegistry.default`.
    pub fn default_registry() -> Self {
        EventKindRegistry {
            specs: Self::default_specs(),
        }
    }

    fn default_specs() -> BTreeMap<EventKindId, EventKindSpec> {
        let mut specs = BTreeMap::new();
        let mut insert = |spec: EventKindSpec| {
            specs.insert(spec.id, spec);
        };

        insert(EventKindSpec::new(
            EventKindId::SceneChanged,
            EventDomain::Scene,
            EventPayloadSchemaId::SceneChanged,
            EventCardinality::PerChange,
            EventOrdering::PerStream,
            false,
            EventRetentionClass::Hot,
            true,
            true,
            Some(EventCoalesceHint::from_keys(
                &["entity_ids"],
                EventCoalesceReducer::KeepLast,
            )),
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::SceneEntityAdded,
            EventDomain::Scene,
            EventPayloadSchemaId::SceneEntityChanged,
            EventCardinality::PerBatch,
            EventOrdering::PerStream,
            false,
            EventRetentionClass::Hot,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::SceneEntityRemoved,
            EventDomain::Scene,
            EventPayloadSchemaId::SceneEntityChanged,
            EventCardinality::PerBatch,
            EventOrdering::PerStream,
            false,
            EventRetentionClass::Hot,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::SequenceChanged,
            EventDomain::Sequence,
            EventPayloadSchemaId::SequenceChanged,
            EventCardinality::PerChange,
            EventOrdering::PerStream,
            false,
            EventRetentionClass::Hot,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::AssetImportFinished,
            EventDomain::Asset,
            EventPayloadSchemaId::AssetImportFinished,
            EventCardinality::PerBatch,
            EventOrdering::PerStream,
            false,
            EventRetentionClass::Warm,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        for kind in [
            EventKindId::TransactionStaged,
            EventKindId::TransactionApplied,
            EventKindId::TransactionDiscarded,
            EventKindId::TransactionFailed,
        ] {
            insert(EventKindSpec::new(
                kind,
                EventDomain::Transaction,
                EventPayloadSchemaId::TransactionLifecycle,
                EventCardinality::PerChange,
                EventOrdering::PerStream,
                false,
                EventRetentionClass::Hot,
                true,
                true,
                None,
                "0.1.0".to_string(),
                None,
            ));
        }
        insert(EventKindSpec::new(
            EventKindId::DiagnosticsWarningRaised,
            EventDomain::Diagnostics,
            EventPayloadSchemaId::DiagnosticsWarningRaised,
            EventCardinality::PerChange,
            EventOrdering::PerStream,
            false,
            EventRetentionClass::Warm,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::SelectionChanged,
            EventDomain::Ui,
            EventPayloadSchemaId::SelectionChanged,
            EventCardinality::PerChange,
            EventOrdering::PerStream,
            true,
            EventRetentionClass::Ephemeral,
            false,
            true,
            Some(EventCoalesceHint::from_keys(
                &["entity_id"],
                EventCoalesceReducer::KeepLast,
            )),
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::ConfirmationRequested,
            EventDomain::Ui,
            EventPayloadSchemaId::ConfirmationRequested,
            EventCardinality::PerChange,
            EventOrdering::PerStream,
            true,
            EventRetentionClass::Warm,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::ConfirmationResolved,
            EventDomain::Ui,
            EventPayloadSchemaId::ConfirmationResolved,
            EventCardinality::PerChange,
            EventOrdering::PerStream,
            true,
            EventRetentionClass::Warm,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::RuntimeTick,
            EventDomain::Runtime,
            EventPayloadSchemaId::RuntimeTick,
            EventCardinality::PerTick,
            EventOrdering::PerStream,
            true,
            EventRetentionClass::Ephemeral,
            false,
            false,
            None,
            "0.1.0".to_string(),
            None,
        ));
        insert(EventKindSpec::new(
            EventKindId::RuntimeMetricSampled,
            EventDomain::Runtime,
            EventPayloadSchemaId::RuntimeMetricSampled,
            EventCardinality::PerBatch,
            EventOrdering::PerStream,
            true,
            EventRetentionClass::Cold,
            true,
            true,
            None,
            "0.1.0".to_string(),
            None,
        ));
        specs
    }
}

impl Default for EventKindRegistry {
    fn default() -> Self {
        Self::default_registry()
    }
}
