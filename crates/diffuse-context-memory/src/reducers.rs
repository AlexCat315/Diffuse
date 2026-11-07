//! `Reducers.swift` — deterministic pure functions from `WorldEvent`s to
//! context-memory mutations.

use std::collections::BTreeMap;
use std::sync::Arc;

use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_kernel::codable::format_float;

use crate::context_entry::{ContextEntry, EntryKind};

/// A mutation a reducer can produce: upsert an entry or delete one by id.
#[derive(Clone, Debug, PartialEq)]
pub enum ContextMemoryMutation {
    Upsert(ContextEntry),
    Delete { id: String },
}

/// A pure function deriving zero or more mutations from a `WorldEvent`.
///
/// Reducers must be deterministic and side-effect free; the identity of entries
/// they create depends only on the event and `existing`, so replaying the same
/// event sequence always yields a bit-equal result. Swift's `@Sendable` closure
/// becomes an `Arc<dyn Fn + Send + Sync>`.
pub type ContextMemoryReducer = Arc<
    dyn Fn(&BTreeMap<String, ContextEntry>, &WorldEvent) -> Vec<ContextMemoryMutation>
        + Send
        + Sync,
>;

type ReducerFn = fn(&BTreeMap<String, ContextEntry>, &WorldEvent) -> Vec<ContextMemoryMutation>;

fn empty() -> Vec<ContextMemoryMutation> {
    Vec::new()
}

fn entry(
    id: impl Into<String>,
    kind: EntryKind,
    subject: impl Into<String>,
    payload: BTreeMap<String, String>,
    importance: f64,
    revision: u64,
) -> ContextMemoryMutation {
    ContextMemoryMutation::Upsert(
        ContextEntry::new(kind, subject, payload)
            .with_id(id)
            .with_importance(importance)
            .with_revision(revision),
    )
}

/// `editAppliedReducer` — keyed by edit id, so replay is idempotent.
pub fn edit_applied(
    _existing: &BTreeMap<String, ContextEntry>,
    event: &WorldEvent,
) -> Vec<ContextMemoryMutation> {
    let WorldEvent::EditApplied {
        edit_id,
        summary,
        revision,
    } = event
    else {
        return empty();
    };
    if edit_id.is_empty() || summary.is_empty() {
        return empty();
    }
    vec![entry(
        format!("edit:{edit_id}"),
        EntryKind::EntityEdit,
        "session",
        BTreeMap::from([
            ("summary".to_string(), summary.clone()),
            ("edit_id".to_string(), edit_id.clone()),
        ]),
        0.4,
        *revision,
    )]
}

/// `entityAddedReducer` — stable `entity_added:<ref>` id.
pub fn entity_added(
    _existing: &BTreeMap<String, ContextEntry>,
    event: &WorldEvent,
) -> Vec<ContextMemoryMutation> {
    let WorldEvent::EntityAdded { ref_, name, kind } = event else {
        return empty();
    };
    let mut payload = BTreeMap::from([
        ("name".to_string(), name.clone()),
        ("ref".to_string(), ref_.clone()),
    ]);
    if let Some(kind) = kind {
        payload.insert("kind".to_string(), kind.clone());
    }
    vec![entry(
        format!("entity_added:{ref_}"),
        EntryKind::SceneAnnotation,
        ref_.clone(),
        payload,
        0.3,
        0,
    )]
}

/// `entityRemovedReducer` — deletes the added entry plus every inferred and
/// percept entry for the removed entity, without leaving tombstones.
pub fn entity_removed(
    existing: &BTreeMap<String, ContextEntry>,
    event: &WorldEvent,
) -> Vec<ContextMemoryMutation> {
    let WorldEvent::EntityRemoved { ref_ } = event else {
        return empty();
    };
    let added_id = format!("entity_added:{ref_}");
    let inferred_prefix = format!("inferred:{ref_}:");
    let percept_prefix = format!("percept:{ref_}:");
    let mut mutations = Vec::new();
    if existing.contains_key(&added_id) {
        mutations.push(ContextMemoryMutation::Delete { id: added_id });
    }
    for key in existing.keys() {
        if key.starts_with(&inferred_prefix) || key.starts_with(&percept_prefix) {
            mutations.push(ContextMemoryMutation::Delete { id: key.clone() });
        }
    }
    mutations
}

/// `entityRenamedReducer` — keeps the entity name in memory current.
pub fn entity_renamed(
    existing: &BTreeMap<String, ContextEntry>,
    event: &WorldEvent,
) -> Vec<ContextMemoryMutation> {
    let WorldEvent::EntityAuthoredChanged {
        ref_,
        property,
        value: WorldPropertyValue::String(new_name),
    } = event
    else {
        return empty();
    };
    if property != "name" {
        return empty();
    }
    let added_id = format!("entity_added:{ref_}");
    let Some(existing_entry) = existing.get(&added_id) else {
        return empty();
    };
    let mut updated = existing_entry.clone();
    updated.payload.insert("name".to_string(), new_name.clone());
    vec![ContextMemoryMutation::Upsert(updated)]
}

/// `highConfidenceInferredReducer` — fires at confidence >= 0.8.
pub fn high_confidence_inferred(
    existing: &BTreeMap<String, ContextEntry>,
    event: &WorldEvent,
) -> Vec<ContextMemoryMutation> {
    let WorldEvent::EntityInferredUpdated {
        ref_,
        property,
        value,
        confidence,
        source,
    } = event
    else {
        return empty();
    };
    if *confidence < 0.8 {
        return empty();
    }
    let entry_id = format!("inferred:{ref_}:{property}");
    let mut payload = BTreeMap::from([
        ("ref".to_string(), ref_.clone()),
        ("property".to_string(), property.clone()),
        ("confidence".to_string(), format!("{confidence:.2}")),
    ]);
    if let Some(source) = source {
        payload.insert("source".to_string(), source.clone());
    }
    payload.insert("value".to_string(), property_value_text(value));
    let previous_revision = existing
        .get(&entry_id)
        .map(|previous| previous.revision)
        .unwrap_or(0);
    vec![entry(
        entry_id,
        EntryKind::SceneAnnotation,
        ref_.clone(),
        payload,
        (0.5 + confidence * 0.5).min(1.0),
        previous_revision,
    )]
}

fn property_value_text(value: &WorldPropertyValue) -> String {
    match value {
        WorldPropertyValue::String(text) => text.clone(),
        WorldPropertyValue::Float(number) => format_percent_g(*number, 4),
        WorldPropertyValue::Bool(flag) => {
            if *flag {
                "true".to_string()
            } else {
                "false".to_string()
            }
        }
        WorldPropertyValue::Json(value) => {
            serde_json::to_string(&value.to_json_value()).unwrap_or_else(|_| "null".to_string())
        }
        WorldPropertyValue::Vec3(x, y, z) => format!(
            "({}, {}, {})",
            swift_float_description(*x),
            swift_float_description(*y),
            swift_float_description(*z)
        ),
        WorldPropertyValue::Vec4(x, y, z, w) => format!(
            "({}, {}, {}, {})",
            swift_float_description(*x),
            swift_float_description(*y),
            swift_float_description(*z),
            swift_float_description(*w)
        ),
    }
}

/// Swift's `String(format: "%.4g", value)`: `significant` significant digits,
/// scientific notation outside `[1e-4, 1e<significant>)`, trailing zeros removed.
fn format_percent_g(value: f32, significant: usize) -> String {
    if value == 0.0 {
        return "0".to_string();
    }
    let exponent = value.abs().log10().floor() as i32;
    let decimals = significant.saturating_sub(1);
    if !(-4..significant as i32).contains(&exponent) {
        let mantissa = value / 10f32.powi(exponent);
        let text = trim_zeros(&format!("{mantissa:.decimals$}"));
        format!("{text}e{exponent:+03}")
    } else {
        let decimal_places = (significant as i32 - 1 - exponent).max(0) as usize;
        trim_zeros(&format!("{value:.decimal_places$}"))
    }
}

fn trim_zeros(text: &str) -> String {
    if text.contains('.') {
        let trimmed = text.trim_end_matches('0').trim_end_matches('.');
        trimmed.to_string()
    } else {
        text.to_string()
    }
}

/// Swift's `"\(float)"` keeps a fractional `.0` on integral values.
fn swift_float_description(value: f32) -> String {
    let text = format_float(value).unwrap_or_else(|| "nan".to_string());
    if !text.contains('.') && !text.contains('e') && !text.contains('E') {
        format!("{text}.0")
    } else {
        text
    }
}

/// Immutable ordered list of reducers; applied in registration order.
#[derive(Clone)]
pub struct ReducerRegistry {
    reducers: Vec<ContextMemoryReducer>,
}

impl ReducerRegistry {
    pub fn new(reducers: Vec<ContextMemoryReducer>) -> Self {
        ReducerRegistry { reducers }
    }

    /// Returns a new registry with `reducer` appended at the end.
    pub fn adding(&self, reducer: ContextMemoryReducer) -> Self {
        let mut reducers = self.reducers.clone();
        reducers.push(reducer);
        ReducerRegistry { reducers }
    }

    pub fn apply(
        &self,
        existing: &BTreeMap<String, ContextEntry>,
        event: &WorldEvent,
    ) -> Vec<ContextMemoryMutation> {
        self.reducers
            .iter()
            .flat_map(|reducer| reducer(existing, event))
            .collect()
    }
}

/// Swift's `ReducerRegistry.default`: the five built-in reducers.
impl Default for ReducerRegistry {
    fn default() -> Self {
        let reducers: Vec<ContextMemoryReducer> = vec![
            Arc::new(edit_applied as ReducerFn),
            Arc::new(entity_added as ReducerFn),
            Arc::new(entity_removed as ReducerFn),
            Arc::new(entity_renamed as ReducerFn),
            Arc::new(high_confidence_inferred as ReducerFn),
        ];
        ReducerRegistry { reducers }
    }
}
