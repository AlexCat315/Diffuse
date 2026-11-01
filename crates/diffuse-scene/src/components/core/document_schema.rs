//! `Core/DocumentSchema.swift` — schemas for components declared by data.
//!
//! Swift's document schema closures capture the `typeID` and the default document,
//! which Rust fn pointers cannot do. The equivalent here is a process-wide slot
//! table: `DocumentComponentSchema::make` appends the captured values once and the
//! schema is wired to const-generic trampolines (`has_slot::<N>` and friends) that
//! read their slot back. Every slot is immutable after allocation, so concurrent
//! reads are safe and the closure semantics are preserved.
//!
//! Storage itself is the world's authored document map, keyed by `typeID`, exactly
//! like `world.documentComponent(_:for:)` in Swift.

use std::sync::{Mutex, OnceLock};

use crate::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentSchema,
    ComponentTypeKey,
};
use crate::components::core::value::ComponentValue;
use crate::entity_id::EntityID;
use crate::runtime_world::RuntimeWorld;

/// Upper bound on document schemas allocated in one process. Declarations are
/// already capped at 32 per payload; this only guards runaway registration.
const MAX_DOCUMENT_SCHEMAS: usize = 256;

/// Swift `DocumentComponentSchema`.
pub enum DocumentComponentSchema {}

impl DocumentComponentSchema {
    /// Swift `make(typeID:displayName:category:defaultDocument:configure:)`.
    pub fn make(
        type_id: impl Into<String>,
        display_name: impl Into<String>,
        category: ComponentCategory,
        default_document: ComponentValue,
        configure: impl FnOnce(&mut ComponentSchema),
    ) -> ComponentSchema {
        let type_id = type_id.into();
        let slot = allocate_document_slot(type_id.clone(), default_document);
        let mut schema = ComponentSchema::from_document(
            type_id.clone(),
            display_name,
            category,
            ComponentTypeKey::new_document(),
        );
        schema.runtime_type_name = format!("document:{type_id}");
        schema.has = has_dispatch(slot);
        schema.encode = encode_dispatch(slot);
        let decode = decode_dispatch(slot);
        schema.decode = decode;
        schema.apply_edit = decode;
        schema.make_default = std::sync::Arc::new(make_default_dispatch(slot));
        schema.remove = remove_dispatch(slot);
        configure(&mut schema);
        schema
    }

    /// `make` with Swift's default `configure` closure.
    pub fn make_with_default(
        type_id: impl Into<String>,
        display_name: impl Into<String>,
        category: ComponentCategory,
        default_document: ComponentValue,
    ) -> ComponentSchema {
        DocumentComponentSchema::make(type_id, display_name, category, default_document, |_| {})
    }
}

struct DocumentSlot {
    type_id: String,
    default_document: ComponentValue,
}

fn document_slots() -> &'static Mutex<Vec<DocumentSlot>> {
    static SLOTS: OnceLock<Mutex<Vec<DocumentSlot>>> = OnceLock::new();
    SLOTS.get_or_init(|| Mutex::new(Vec::new()))
}

fn allocate_document_slot(type_id: String, default_document: ComponentValue) -> usize {
    let mut slots = document_slots()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert!(
        slots.len() < MAX_DOCUMENT_SCHEMAS,
        "Too many document component schemas: at most {MAX_DOCUMENT_SCHEMAS} may be registered per process"
    );
    slots.push(DocumentSlot {
        type_id,
        default_document,
    });
    slots.len() - 1
}

fn with_document_slot<R>(index: usize, lookup: impl FnOnce(&DocumentSlot) -> R) -> R {
    let slots = document_slots()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match slots.get(index) {
        Some(slot) => lookup(slot),
        None => unreachable_slot(index),
    }
}

fn unreachable_slot(index: usize) -> ! {
    panic!("Document component schema slot {index} is not allocated")
}

fn has_slot<const SLOT: usize>(world: &RuntimeWorld, entity: EntityID) -> bool {
    let type_id = with_document_slot(SLOT, |slot| slot.type_id.clone());
    world.has_document_component(&type_id, entity)
}

fn encode_slot<const SLOT: usize>(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    let type_id = with_document_slot(SLOT, |slot| slot.type_id.clone());
    world.document_component(&type_id, entity).cloned()
}

fn decode_slot<const SLOT: usize>(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let type_id = with_document_slot(SLOT, |slot| slot.type_id.clone());
    let _ = world.set_document_component(&type_id, value.clone(), entity);
}

fn make_default_slot<const SLOT: usize>(entity: EntityID, world: &mut RuntimeWorld) {
    let (type_id, default_document) = with_document_slot(SLOT, |slot| {
        (slot.type_id.clone(), slot.default_document.clone())
    });
    let _ = world.set_document_component(&type_id, default_document, entity);
}

fn remove_slot<const SLOT: usize>(entity: EntityID, world: &mut RuntimeWorld) {
    let type_id = with_document_slot(SLOT, |slot| slot.type_id.clone());
    let _ = world.remove_document_component(&type_id, entity);
}

type HasFn = fn(&RuntimeWorld, EntityID) -> bool;
type EncodeFn = fn(&RuntimeWorld, EntityID, &mut ComponentEncodeContext) -> Option<ComponentValue>;
type DecodeFn = fn(&ComponentValue, EntityID, &mut ComponentDecodeContext, &mut RuntimeWorld);
type DefaultFn = fn(EntityID, &mut RuntimeWorld);

fn missing_has(_: &RuntimeWorld, _: EntityID) -> bool {
    panic!("Document component schema slot is out of range")
}

fn missing_encode(
    _: &RuntimeWorld,
    _: EntityID,
    _: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    panic!("Document component schema slot is out of range")
}

fn missing_decode(
    _: &ComponentValue,
    _: EntityID,
    _: &mut ComponentDecodeContext,
    _: &mut RuntimeWorld,
) {
    panic!("Document component schema slot is out of range")
}

fn missing_default(_: EntityID, _: &mut RuntimeWorld) {
    panic!("Document component schema slot is out of range")
}

/// Lists the const-generic slots understood by the dispatchers below.
macro_rules! document_slots {
    ($callback:ident) => {
        $callback!(
            0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
            16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
            32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47
            48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63
            64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79
            80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95
            96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111
            112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127
            128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143
            144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159
            160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175
            176 177 178 179 180 181 182 183 184 185 186 187 188 189 190 191
            192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207
            208 209 210 211 212 213 214 215 216 217 218 219 220 221 222 223
            224 225 226 227 228 229 230 231 232 233 234 235 236 237 238 239
            240 241 242 243 244 245 246 247 248 249 250 251 252 253 254 255
        );
    };
}

macro_rules! define_has_dispatch {
    ($($slot:literal)*) => {
        fn has_dispatch(index: usize) -> HasFn {
            match index {
                $($slot => has_slot::<$slot>,)*
                _ => missing_has,
            }
        }
    };
}
document_slots!(define_has_dispatch);

macro_rules! define_encode_dispatch {
    ($($slot:literal)*) => {
        fn encode_dispatch(index: usize) -> EncodeFn {
            match index {
                $($slot => encode_slot::<$slot>,)*
                _ => missing_encode,
            }
        }
    };
}
document_slots!(define_encode_dispatch);

macro_rules! define_decode_dispatch {
    ($($slot:literal)*) => {
        fn decode_dispatch(index: usize) -> DecodeFn {
            match index {
                $($slot => decode_slot::<$slot>,)*
                _ => missing_decode,
            }
        }
    };
}
document_slots!(define_decode_dispatch);

macro_rules! define_default_dispatch {
    ($($slot:literal)*) => {
        fn make_default_dispatch(index: usize) -> DefaultFn {
            match index {
                $($slot => make_default_slot::<$slot>,)*
                _ => missing_default,
            }
        }
    };
}
document_slots!(define_default_dispatch);

macro_rules! define_remove_dispatch {
    ($($slot:literal)*) => {
        fn remove_dispatch(index: usize) -> DefaultFn {
            match index {
                $($slot => remove_slot::<$slot>,)*
                _ => missing_default,
            }
        }
    };
}
document_slots!(define_remove_dispatch);

#[cfg(test)]
mod tests {
    use super::*;

    fn object(fields: [(&str, ComponentValue); 1]) -> ComponentValue {
        ComponentValue::Object(
            fields
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect(),
        )
    }

    #[test]
    fn a_document_schema_round_trips_through_the_world() {
        let default_document = object([("amount", ComponentValue::Number(3.0))]);
        let schema = DocumentComponentSchema::make_with_default(
            "mod.health",
            "Health",
            ComponentCategory::Gameplay,
            default_document.clone(),
        );
        assert_eq!(schema.runtime_type_name, "document:mod.health");
        assert_eq!(schema.type_id, "mod.health");

        let mut world = RuntimeWorld::default();
        let entity = world.create_entity();
        (schema.make_default)(entity, &mut world);
        assert!((schema.has)(&world, entity));
        let mut context = ComponentEncodeContext::default();
        assert_eq!(
            (schema.encode)(&world, entity, &mut context),
            Some(default_document)
        );

        let replacement = object([("amount", ComponentValue::Number(9.0))]);
        let mut decode_context = ComponentDecodeContext::default();
        (schema.decode)(&replacement, entity, &mut decode_context, &mut world);
        assert_eq!(
            world.document_component("mod.health", entity),
            Some(&replacement)
        );

        (schema.remove)(entity, &mut world);
        assert!(!(schema.has)(&world, entity));
    }

    #[test]
    fn configure_runs_after_the_document_wiring() {
        let schema = DocumentComponentSchema::make(
            "mod.armor",
            "Armor",
            ComponentCategory::Gameplay,
            object([("value", ComponentValue::Number(1.0))]),
            |schema| {
                schema.requires = vec!["mod.health".to_string()];
                schema.is_user_addable = false;
            },
        );
        assert_eq!(schema.requires, vec!["mod.health".to_string()]);
        assert!(!schema.is_user_addable);
        assert_eq!(schema.runtime_type_name, "document:mod.armor");
    }

    #[test]
    fn each_schema_gets_its_own_identity() {
        let first = DocumentComponentSchema::make_with_default(
            "mod.a",
            "A",
            ComponentCategory::Scripting,
            ComponentValue::Null,
        );
        let second = DocumentComponentSchema::make_with_default(
            "mod.b",
            "B",
            ComponentCategory::Scripting,
            ComponentValue::Null,
        );
        assert_ne!(first.component_type_id, second.component_type_id);
    }
}
