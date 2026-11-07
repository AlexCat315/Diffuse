//! `ContextMemoryTests.swift` — Swift Testing suite, 1:1.

use std::collections::BTreeMap;
use std::sync::Arc;

use diffuse_context_memory::context_entry::{ContextEntry, EntryKind};
use diffuse_context_memory::context_memory_store::ContextMemoryStore;
use diffuse_context_memory::reducers::{
    ContextMemoryMutation, ContextMemoryReducer, ReducerRegistry, edit_applied, entity_added,
    entity_removed, entity_renamed, high_confidence_inferred,
};
use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_kernel::codable::new_uuid;

fn upserts(mutations: &[ContextMemoryMutation]) -> Vec<ContextEntry> {
    mutations
        .iter()
        .filter_map(|mutation| match mutation {
            ContextMemoryMutation::Upsert(item) => Some(item.clone()),
            _ => None,
        })
        .collect()
}

fn deleted_ids(mutations: &[ContextMemoryMutation]) -> Vec<String> {
    mutations
        .iter()
        .filter_map(|mutation| match mutation {
            ContextMemoryMutation::Delete { id } => Some(id.clone()),
            _ => None,
        })
        .collect()
}

fn payload(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
        .collect()
}

fn entry(id: &str, kind: EntryKind, subject: &str, values: &[(&str, &str)]) -> ContextEntry {
    ContextEntry::new(kind, subject, payload(values)).with_id(id)
}

fn edited(edit_id: &str, summary: &str, revision: u64) -> WorldEvent {
    WorldEvent::EditApplied {
        edit_id: edit_id.to_string(),
        summary: summary.to_string(),
        revision,
    }
}

/// "editAppliedReducer produces entityEdit entry from editApplied event"
#[test]
fn edit_applied_reducer_produces_entry() {
    let existing = BTreeMap::new();
    let entries = upserts(&edit_applied(&existing, &edited("e1", "moved cube", 1)));
    assert_eq!(entries.len(), 1);
    let item = &entries[0];
    assert_eq!(item.id, "edit:e1");
    assert_eq!(item.kind, EntryKind::EntityEdit);
    assert_eq!(item.subject, "session");
    assert_eq!(
        item.payload.get("summary").map(String::as_str),
        Some("moved cube")
    );
    assert_eq!(item.payload.get("edit_id").map(String::as_str), Some("e1"));
    assert_eq!(item.revision, 1);
}

/// "editAppliedReducer returns empty for empty editID"
#[test]
fn edit_applied_reducer_rejects_empty_id() {
    assert!(edit_applied(&BTreeMap::new(), &edited("", "x", 0)).is_empty());
}

/// "editAppliedReducer returns empty for empty summary"
#[test]
fn edit_applied_reducer_rejects_empty_summary() {
    assert!(edit_applied(&BTreeMap::new(), &edited("e2", "", 0)).is_empty());
}

/// "editAppliedReducer is idempotent on replay (stable fields)"
#[test]
fn edit_applied_reducer_is_idempotent() {
    let event = edited("e3", "rename", 5);
    let first = upserts(&edit_applied(&BTreeMap::new(), &event));
    let mut existing = BTreeMap::new();
    for item in &first {
        existing.insert(item.id.clone(), item.clone());
    }
    let second = upserts(&edit_applied(&existing, &event));
    assert_eq!(first.len(), second.len());
    for (left, right) in first.iter().zip(&second) {
        assert_eq!(left.id, right.id);
        assert_eq!(left.kind, right.kind);
        assert_eq!(left.subject, right.subject);
        assert_eq!(left.payload, right.payload);
        assert_eq!(left.importance, right.importance);
        assert_eq!(left.revision, right.revision);
    }
}

/// "entityAddedReducer produces sceneAnnotation from entityAdded"
#[test]
fn entity_added_reducer_produces_entry() {
    let event = WorldEvent::EntityAdded {
        ref_: "scene:7".into(),
        name: "Cube".into(),
        kind: Some("mesh".into()),
    };
    let entries = upserts(&entity_added(&BTreeMap::new(), &event));
    assert_eq!(entries.len(), 1);
    let item = &entries[0];
    assert_eq!(item.id, "entity_added:scene:7");
    assert_eq!(item.kind, EntryKind::SceneAnnotation);
    assert_eq!(item.subject, "scene:7");
    assert_eq!(item.payload.get("name").map(String::as_str), Some("Cube"));
    assert_eq!(item.payload.get("ref").map(String::as_str), Some("scene:7"));
    assert_eq!(item.payload.get("kind").map(String::as_str), Some("mesh"));
}

/// "entityAddedReducer omits kind when nil"
#[test]
fn entity_added_reducer_omits_nil_kind() {
    let event = WorldEvent::EntityAdded {
        ref_: "scene:8".into(),
        name: "Empty".into(),
        kind: None,
    };
    let entries = upserts(&entity_added(&BTreeMap::new(), &event));
    assert_eq!(entries[0].payload.get("kind"), None);
}

/// "entityAddedReducer returns empty for non-entityAdded events"
#[test]
fn entity_added_reducer_ignores_other_events() {
    assert!(entity_added(&BTreeMap::new(), &edited("x", "y", 0)).is_empty());
}

/// "entityRemovedReducer deletes entity_added entry"
#[test]
fn entity_removed_reducer_deletes_added_entry() {
    let existing = BTreeMap::from([(
        "entity_added:scene:5".to_string(),
        entry(
            "entity_added:scene:5",
            EntryKind::SceneAnnotation,
            "scene:5",
            &[],
        ),
    )]);
    let mutations = entity_removed(
        &existing,
        &WorldEvent::EntityRemoved {
            ref_: "scene:5".into(),
        },
    );
    assert!(deleted_ids(&mutations).contains(&"entity_added:scene:5".to_string()));
}

/// "entityRemovedReducer deletes all inferred entries for removed entity"
#[test]
fn entity_removed_reducer_deletes_inferred_entries() {
    let mut existing = BTreeMap::new();
    for id in [
        "entity_added:scene:6",
        "inferred:scene:6:material",
        "inferred:scene:6:roughness",
        "entity_added:scene:7",
    ] {
        existing.insert(
            id.to_string(),
            entry(id, EntryKind::SceneAnnotation, "scene:6", &[]),
        );
    }
    let mutations = entity_removed(
        &existing,
        &WorldEvent::EntityRemoved {
            ref_: "scene:6".into(),
        },
    );
    let ids: BTreeMap<String, ()> = deleted_ids(&mutations)
        .into_iter()
        .map(|id| (id, ()))
        .collect();
    assert!(ids.contains_key("entity_added:scene:6"));
    assert!(ids.contains_key("inferred:scene:6:material"));
    assert!(ids.contains_key("inferred:scene:6:roughness"));
    assert!(!ids.contains_key("entity_added:scene:7"));
}

/// "entityRemovedReducer deletes percept entries written by session.tagEntity"
#[test]
fn entity_removed_reducer_deletes_percept_entries() {
    let mut existing = BTreeMap::new();
    for (id, value) in [
        ("percept:scene:7:object_category", "chair"),
        ("percept:scene:7:perception.summary", "chair"),
        ("percept:scene:8:object_category", "table"),
    ] {
        existing.insert(
            id.to_string(),
            entry(
                id,
                EntryKind::SceneAnnotation,
                "scene:7",
                &[("property", "object_category"), ("value", value)],
            ),
        );
    }
    let mutations = entity_removed(
        &existing,
        &WorldEvent::EntityRemoved {
            ref_: "scene:7".into(),
        },
    );
    let ids: BTreeMap<String, ()> = deleted_ids(&mutations)
        .into_iter()
        .map(|id| (id, ()))
        .collect();
    assert_eq!(
        ids.keys().cloned().collect::<Vec<_>>(),
        vec![
            "percept:scene:7:object_category".to_string(),
            "percept:scene:7:perception.summary".to_string(),
        ]
    );
}

/// "entityRemovedReducer returns empty when entity has no memory entries"
#[test]
fn entity_removed_reducer_returns_empty_for_unknown_entity() {
    assert!(
        entity_removed(
            &BTreeMap::new(),
            &WorldEvent::EntityRemoved {
                ref_: "scene:99".into()
            }
        )
        .is_empty()
    );
}

/// "entityRemovedReducer ignores non-entityRemoved events"
#[test]
fn entity_removed_reducer_ignores_other_events() {
    let event = WorldEvent::EntityAdded {
        ref_: "scene:1".into(),
        name: "X".into(),
        kind: None,
    };
    assert!(entity_removed(&BTreeMap::new(), &event).is_empty());
}

fn renamed(ref_: &str, property: &str, value: WorldPropertyValue) -> WorldEvent {
    WorldEvent::EntityAuthoredChanged {
        ref_: ref_.into(),
        property: property.into(),
        value,
    }
}

/// "entityRenamedReducer updates name in entity_added entry"
#[test]
fn entity_renamed_reducer_updates_name() {
    let existing = BTreeMap::from([(
        "entity_added:scene:9".to_string(),
        entry(
            "entity_added:scene:9",
            EntryKind::SceneAnnotation,
            "scene:9",
            &[("name", "OldName"), ("ref", "scene:9")],
        ),
    )]);
    let mutations = entity_renamed(
        &existing,
        &renamed(
            "scene:9",
            "name",
            WorldPropertyValue::String("NewName".into()),
        ),
    );
    let entries = upserts(&mutations);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, "entity_added:scene:9");
    assert_eq!(
        entries[0].payload.get("name").map(String::as_str),
        Some("NewName")
    );
}

/// "entityRenamedReducer does nothing when entity has no memory entry"
#[test]
fn entity_renamed_reducer_ignores_missing_entity() {
    assert!(
        entity_renamed(
            &BTreeMap::new(),
            &renamed("scene:99", "name", WorldPropertyValue::String("X".into()))
        )
        .is_empty()
    );
}

/// "entityRenamedReducer ignores non-name property changes"
#[test]
fn entity_renamed_reducer_ignores_other_properties() {
    let existing = BTreeMap::from([(
        "entity_added:scene:10".to_string(),
        entry(
            "entity_added:scene:10",
            EntryKind::SceneAnnotation,
            "scene:10",
            &[],
        ),
    )]);
    let event = renamed(
        "scene:10",
        "position",
        WorldPropertyValue::Vec3(1.0, 2.0, 3.0),
    );
    assert!(entity_renamed(&existing, &event).is_empty());
}

/// "store updates entity name in memory after rename event"
#[test]
fn store_updates_name_on_rename_event() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:15".into(),
        name: "Initial".into(),
        kind: None,
    });
    store.apply(&renamed(
        "scene:15",
        "name",
        WorldPropertyValue::String("Renamed".into()),
    ));
    let item = store.entry("entity_added:scene:15").expect("entry");
    assert_eq!(
        item.payload.get("name").map(String::as_str),
        Some("Renamed")
    );
}

fn inferred(
    ref_: &str,
    property: &str,
    value: WorldPropertyValue,
    confidence: f64,
    source: Option<&str>,
) -> WorldEvent {
    WorldEvent::EntityInferredUpdated {
        ref_: ref_.into(),
        property: property.into(),
        value,
        confidence,
        source: source.map(str::to_string),
    }
}

/// "highConfidenceInferredReducer fires at exactly 0.8 confidence"
#[test]
fn high_confidence_reducer_at_threshold() {
    let event = inferred(
        "scene:10",
        "material",
        WorldPropertyValue::String("wood".into()),
        0.8,
        None,
    );
    let entries = upserts(&high_confidence_inferred(&BTreeMap::new(), &event));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, "inferred:scene:10:material");
    assert_eq!(
        entries[0].payload.get("value").map(String::as_str),
        Some("wood")
    );
}

/// "highConfidenceInferredReducer rejects confidence below 0.8"
#[test]
fn high_confidence_reducer_below_threshold() {
    let event = inferred(
        "scene:10",
        "material",
        WorldPropertyValue::String("wood".into()),
        0.79,
        None,
    );
    assert!(high_confidence_inferred(&BTreeMap::new(), &event).is_empty());
}

/// "highConfidenceInferredReducer preserves previous revision"
#[test]
fn high_confidence_reducer_preserves_revision() {
    let entry_id = "inferred:scene:11:roughness";
    let previous = entry(
        entry_id,
        EntryKind::SceneAnnotation,
        "scene:11",
        &[("value", "0.3")],
    )
    .with_importance(0.9)
    .with_revision(42);
    let existing = BTreeMap::from([(entry_id.to_string(), previous)]);
    let event = inferred(
        "scene:11",
        "roughness",
        WorldPropertyValue::Float(0.5),
        0.95,
        Some("VisionAdapter"),
    );
    let entries = upserts(&high_confidence_inferred(&existing, &event));
    assert_eq!(entries[0].revision, 42);
    assert_eq!(
        entries[0].payload.get("source").map(String::as_str),
        Some("VisionAdapter")
    );
}

/// "highConfidenceInferredReducer encodes all value variants"
///
/// Swift's fixture is the literal `3.14`, not π; keeping the input unchanged is
/// what makes the `%.4g` assertion meaningful.
#[allow(clippy::approx_constant)]
#[test]
fn high_confidence_reducer_value_variants() {
    let value_of = |value: WorldPropertyValue| {
        let event = inferred("scene:1", "p", value, 1.0, None);
        let entries = upserts(&high_confidence_inferred(&BTreeMap::new(), &event));
        entries[0]
            .payload
            .get("value")
            .cloned()
            .expect("value present")
    };
    assert_eq!(value_of(WorldPropertyValue::Float(3.14)), "3.14");
    assert_eq!(value_of(WorldPropertyValue::Bool(true)), "true");
    assert_eq!(
        value_of(WorldPropertyValue::Vec3(1.0, 2.0, 3.0)),
        "(1.0, 2.0, 3.0)"
    );
    assert_eq!(
        value_of(WorldPropertyValue::Vec4(1.0, 2.0, 3.0, 4.0)),
        "(1.0, 2.0, 3.0, 4.0)"
    );
}

/// "ReducerRegistry.default applies all four built-in reducers"
#[test]
fn default_registry_applies_all_reducers() {
    let registry = ReducerRegistry::default();
    let edit = registry.apply(&BTreeMap::new(), &edited("e99", "test", 0));
    let add = registry.apply(
        &BTreeMap::new(),
        &WorldEvent::EntityAdded {
            ref_: "scene:99".into(),
            name: "S".into(),
            kind: None,
        },
    );
    let infer = registry.apply(
        &BTreeMap::new(),
        &inferred(
            "scene:99",
            "color",
            WorldPropertyValue::String("red".into()),
            0.9,
            None,
        ),
    );
    assert!(!upserts(&edit).is_empty());
    assert!(!upserts(&add).is_empty());
    assert!(!upserts(&infer).is_empty());
}

/// "ReducerRegistry.adding accumulates mutations from both reducers"
#[test]
fn registry_adding_accumulates_results() {
    let r1: ContextMemoryReducer =
        Arc::new(|_: &BTreeMap<String, ContextEntry>, _: &WorldEvent| {
            vec![ContextMemoryMutation::Upsert(entry(
                "r1",
                EntryKind::EntityEdit,
                "s",
                &[],
            ))]
        });
    let r2: ContextMemoryReducer =
        Arc::new(|_: &BTreeMap<String, ContextEntry>, _: &WorldEvent| {
            vec![ContextMemoryMutation::Upsert(entry(
                "r2",
                EntryKind::SceneAnnotation,
                "s",
                &[],
            ))]
        });
    let registry = ReducerRegistry::new(vec![r1]).adding(r2);
    let mutations = registry.apply(&BTreeMap::new(), &edited("x", "y", 0));
    let ids: Vec<String> = upserts(&mutations)
        .into_iter()
        .map(|item| item.id)
        .collect();
    assert!(ids.contains(&"r1".to_string()));
    assert!(ids.contains(&"r2".to_string()));
}

/// "store.apply upserts entries from events"
#[test]
fn store_apply_upserts() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:1".into(),
        name: "A".into(),
        kind: None,
    });
    let entries = store.all_entries();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].subject, "scene:1");
}

/// "store.apply deletes entries on entityRemoved"
#[test]
fn store_apply_deletes_on_removal() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:1".into(),
        name: "A".into(),
        kind: None,
    });
    store.apply(&WorldEvent::EntityRemoved {
        ref_: "scene:1".into(),
    });
    assert!(store.all_entries().is_empty());
}

/// "store.apply batch is equivalent to sequential apply"
#[test]
fn store_apply_batch_equivalent() {
    let first = ContextMemoryStore::new().expect("store");
    let second = ContextMemoryStore::new().expect("store");
    let events = vec![
        WorldEvent::EntityAdded {
            ref_: "scene:2".into(),
            name: "B".into(),
            kind: Some("mesh".into()),
        },
        edited("e1", "moved", 1),
    ];
    for event in &events {
        first.apply(event);
    }
    second.apply_events(&events);
    let ids = |store: &ContextMemoryStore| {
        store
            .all_entries()
            .into_iter()
            .map(|item| item.id)
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(&first), ids(&second));
}

/// "store replay is idempotent"
#[test]
fn store_replay_is_idempotent() {
    let store = ContextMemoryStore::new().expect("store");
    let events = vec![
        WorldEvent::EntityAdded {
            ref_: "scene:3".into(),
            name: "C".into(),
            kind: None,
        },
        edited("e2", "rotated", 2),
    ];
    store.apply_events(&events);
    let before = store.all_entries();
    store.apply_events(&events);
    let after = store.all_entries();
    assert_eq!(before.len(), after.len());
    let ids = |items: &[ContextEntry]| items.iter().map(|item| item.id.clone()).collect::<Vec<_>>();
    assert_eq!(ids(&before), ids(&after));
}

/// "store evicts lowest-importance entries when at capacity"
#[test]
fn store_evicts_at_capacity() {
    let store = ContextMemoryStore::with_capacity(2).expect("store");
    for reference in ["scene:10", "scene:11"] {
        store.apply(&WorldEvent::EntityAdded {
            ref_: reference.into(),
            name: "X".into(),
            kind: None,
        });
    }
    store.apply(&edited("e10", "edit", 1));
    let entries = store.all_entries();
    assert_eq!(entries.len(), 2);
    assert!(
        entries
            .iter()
            .any(|item| item.kind == EntryKind::EntityEdit)
    );
}

/// "store.lookup(subject:) filters by subject"
#[test]
fn store_lookup_by_subject() {
    let store = ContextMemoryStore::new().expect("store");
    for (reference, name, kind) in [
        ("scene:5", "Light", Some("light")),
        ("scene:6", "Cam", Some("camera")),
    ] {
        store.apply(&WorldEvent::EntityAdded {
            ref_: reference.into(),
            name: name.into(),
            kind: kind.map(str::to_string),
        });
    }
    let results = store.lookup_subject("scene:5");
    assert_eq!(results.len(), 1);
    assert_eq!(
        results[0].payload.get("name").map(String::as_str),
        Some("Light")
    );
}

/// "store.lookup(kind:) filters by kind"
#[test]
fn store_lookup_by_kind() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:7".into(),
        name: "Mesh".into(),
        kind: None,
    });
    store.apply(&edited("e5", "scaled", 3));
    assert_eq!(store.lookup_kind(EntryKind::SceneAnnotation).len(), 1);
    assert_eq!(store.lookup_kind(EntryKind::EntityEdit).len(), 1);
}

/// "store.entry(id:) returns entry or nil"
#[test]
fn store_entry_by_id() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&edited("e6", "deleted", 4));
    assert!(store.entry("edit:e6").is_some());
    assert!(store.entry("nonexistent").is_none());
}

/// "symbolicView respects budget cap"
#[test]
fn symbolic_view_respects_budget() {
    let store = ContextMemoryStore::with_capacity(100).expect("store");
    for index in 0..10 {
        store.apply(&WorldEvent::EntityAdded {
            ref_: format!("scene:{index}"),
            name: format!("E{index}"),
            kind: None,
        });
    }
    assert_eq!(store.symbolic_view(3).len(), 3);
}

/// "symbolicView entries contain required keys"
#[test]
fn symbolic_view_contains_required_keys() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:20".into(),
        name: "Rock".into(),
        kind: Some("mesh".into()),
    });
    let view = store.symbolic_view(10);
    assert_eq!(view.len(), 1);
    let item = &view[0];
    assert!(item.contains_key("id"));
    assert!(item.contains_key("kind"));
    assert!(item.contains_key("subject"));
    assert_eq!(item.get("name").map(String::as_str), Some("Rock"));
}

/// "store.upsert inserts or updates an entry directly"
#[test]
fn store_manual_upsert() {
    let store = ContextMemoryStore::new().expect("store");
    store.upsert(
        entry(
            "pref:test",
            EntryKind::UserPreference,
            "session",
            &[("key", "val")],
        )
        .with_importance(0.7),
    );
    let found = store.entry("pref:test").expect("entry");
    assert_eq!(found.kind, EntryKind::UserPreference);
    assert_eq!(found.payload.get("key").map(String::as_str), Some("val"));
}

/// "store.remove deletes entry by id"
#[test]
fn store_manual_remove() {
    let store = ContextMemoryStore::new().expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:50".into(),
        name: "X".into(),
        kind: None,
    });
    assert!(store.entry("entity_added:scene:50").is_some());
    store.remove("entity_added:scene:50");
    assert!(store.entry("entity_added:scene:50").is_none());
}

/// "store.upsert respects capacity eviction"
#[test]
fn store_upsert_respects_capacity() {
    let store = ContextMemoryStore::with_capacity(2).expect("store");
    for (id, importance) in [("a", 0.1), ("b", 0.2), ("c", 0.9)] {
        store.upsert(entry(id, EntryKind::UserPreference, "s", &[]).with_importance(importance));
    }
    assert_eq!(store.all_entries().len(), 2);
    assert!(store.entry("a").is_none());
    assert!(store.entry("c").is_some());
}

/// "flush and reload round-trip preserves entries"
#[test]
fn flush_and_reload_round_trip() {
    let directory = tempfile::tempdir().expect("tempdir");
    let url = directory
        .path()
        .join(format!("context_memory_{}.json", new_uuid()));
    let store = ContextMemoryStore::with_storage(&url).expect("store");
    store.apply(&WorldEvent::EntityAdded {
        ref_: "scene:30".into(),
        name: "Tree".into(),
        kind: Some("mesh".into()),
    });
    store.apply(&edited("e20", "painted", 5));
    store.flush().expect("flush");

    let reloaded = ContextMemoryStore::with_storage(&url).expect("reload");
    let entries = reloaded.all_entries();
    assert_eq!(entries.len(), 2);
    assert!(
        entries
            .iter()
            .any(|item| item.id == "entity_added:scene:30")
    );
    assert!(entries.iter().any(|item| item.id == "edit:e20"));
}

/// "flush creates missing parent directories and writes deterministic entry order"
#[test]
fn flush_creates_parents_and_sorts_entries() {
    let directory = tempfile::tempdir().expect("tempdir");
    let url = directory.path().join("nested/context_memory.json");
    let store = ContextMemoryStore::with_storage(&url).expect("store");
    for id in ["z", "a"] {
        store.upsert(entry(id, EntryKind::UserPreference, id, &[]).with_importance(1.0));
    }
    store.flush().expect("flush");
    assert!(url.exists());
    let decoded: Vec<ContextEntry> =
        serde_json::from_slice(&std::fs::read(&url).expect("read")).expect("decode");
    assert_eq!(
        decoded
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>(),
        vec!["a".to_string(), "z".to_string()]
    );
}

/// "eviction uses timestamp as tiebreaker when importance is equal"
#[test]
fn eviction_timestamp_tiebreaker_evicts_oldest() {
    let store = ContextMemoryStore::with_capacity(2).expect("store");
    for (id, timestamp) in [("old", 1000.0), ("mid", 2000.0), ("new", 3000.0)] {
        store.upsert(
            entry(id, EntryKind::UserPreference, "s", &[])
                .with_importance(0.5)
                .with_timestamp(timestamp),
        );
    }
    assert_eq!(store.all_entries().len(), 2);
    assert!(
        store.entry("old").is_none(),
        "oldest entry must be evicted on tie"
    );
    assert!(store.entry("mid").is_some());
    assert!(store.entry("new").is_some());
}
