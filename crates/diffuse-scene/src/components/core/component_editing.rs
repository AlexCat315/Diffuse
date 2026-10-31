//! `Core/ComponentEditing.swift` — registry-backed component edits on a
//! `SceneRuntime`.
//!
//! Every entry point reads the registry by `typeID` so editor transactions,
//! prefabs and the script API share one code path with the codecs. Swift mutates a
//! copy of the runtime and assigns it back on success; the Rust equivalent copies
//! the world (`RuntimeWorld` is `Clone`) and only writes it back after the
//! post-edit verification passes, so a failed edit leaves the runtime untouched.

use std::collections::BTreeMap;

use crate::components::core::registry::{
    ComponentDecodeContext, ComponentEncodeContext, ComponentEncodePurpose, ComponentSchema,
};
use crate::components::core::value::{ComponentValue, ManifestComponent};
use crate::components::editing::{ComponentEditError, ComponentWriteMode};
use crate::components::required_components::{
    ComponentEditFailure, ensure_required_components, make_default_component,
};
use crate::entity_id::EntityID;
use crate::runtime_world::RuntimeWorld;
use crate::scene_runtime::SceneRuntime;

/// `Int(bitPattern: UInt($0.rawValue))` — the signed reinterpretation that keeps
/// IDs above `Int.max` distinct.
#[inline]
fn signed_raw_value(entity: EntityID) -> i64 {
    entity.raw_value() as i64
}

fn entity_index_map(world: &RuntimeWorld) -> BTreeMap<EntityID, i64> {
    world
        .entities()
        .into_iter()
        .map(|entity| (entity, signed_raw_value(entity)))
        .collect()
}

fn entity_map(world: &RuntimeWorld) -> BTreeMap<i64, EntityID> {
    world
        .entities()
        .into_iter()
        .map(|entity| (signed_raw_value(entity), entity))
        .collect()
}

/// Swift `schema.encode` through a fresh `.transaction` context.
fn component_data_in(
    world: &RuntimeWorld,
    schema: &ComponentSchema,
    entity: EntityID,
) -> Option<ComponentValue> {
    let mut context = ComponentEncodeContext::new(entity_index_map(world));
    context.purpose = ComponentEncodePurpose::Transaction;
    (schema.encode)(world, entity, &mut context)
}

impl SceneRuntime {
    /// Swift `hasComponent(typeID:for:)`.
    ///
    /// Named `has_component_by_type_id` because Rust has no overloading and
    /// `SceneRuntime::has_component` is the generic `RuntimeComponent` probe.
    pub fn has_component_by_type_id(&self, type_id: &str, entity: EntityID) -> bool {
        let Some(schema) = self.component_registry().get(type_id) else {
            return false;
        };
        self.read_world(|world| (schema.has)(world, entity))
    }

    /// Duplicates every non-structural component document onto `destination`.
    ///
    /// Entity references are rewritten so the source's index maps to the
    /// destination, mirroring how prefab instancing remaps endpoints.
    pub fn duplicate_component_data(&mut self, source: EntityID, destination: EntityID) {
        let components: Vec<ManifestComponent> = self
            .component_registry()
            .component_schemas()
            .into_iter()
            .filter_map(|schema| {
                self.component_data(&schema.type_id, source)
                    .map(|value| ManifestComponent::new(schema.type_id.clone(), value))
            })
            .collect();
        let mut references: BTreeMap<i64, EntityID> = entity_map(self.world());
        references.insert(signed_raw_value(source), destination);
        let mut context = ComponentDecodeContext::new(references);
        let world = self.world_mut();
        for component in &components {
            let Some(schema) = world.component_registry.get(&component.type_id).cloned() else {
                continue;
            };
            (schema.decode)(&component.value, destination, &mut context, world);
            (schema.after_duplicate)(destination, world);
        }
    }

    /// Transaction documents refer to generation-qualified entity IDs, independent
    /// of traversal order. The signed bit pattern also preserves IDs above
    /// `i64::MAX`.
    pub fn component_data(&self, type_id: &str, entity: EntityID) -> Option<ComponentValue> {
        let schema = self.component_registry().get(type_id)?;
        self.read_world(|world| component_data_in(world, schema, entity))
    }

    /// Replaces or merges one component document.
    ///
    /// Merge mode normalizes partial input, merges it into the previous document,
    /// installs required dependencies, applies the edit and re-encodes the result
    /// to confirm every addressed field survived.
    pub fn set_component_data(
        &mut self,
        value: &ComponentValue,
        type_id: &str,
        entity: EntityID,
        mode: ComponentWriteMode,
    ) -> Result<(), ComponentEditFailure> {
        let schema = self
            .component_registry()
            .get(type_id)
            .cloned()
            .ok_or_else(|| ComponentEditError::UnknownType(type_id.to_string()))?;
        if !value.is_finite_json() {
            return Err(ComponentEditError::InvalidValue(type_id.to_string()).into());
        }
        let previous = self.component_data(type_id, entity);
        if mode == ComponentWriteMode::Merge && previous.is_none() {
            return Err(ComponentEditError::MissingComponent(type_id.to_string()).into());
        }
        let normalized = if mode == ComponentWriteMode::Merge {
            match schema.normalize_changes {
                Some(normalize_changes) => (normalize_changes)(
                    previous.as_ref().expect("merge requires a previous value"),
                    value,
                )?,
                None => value.clone(),
            }
        } else {
            value.clone()
        };
        if !normalized.is_finite_json() {
            return Err(ComponentEditError::InvalidValue(type_id.to_string()).into());
        }
        let data = if mode == ComponentWriteMode::Merge {
            (schema.merge)(
                previous.as_ref().expect("merge requires a previous value"),
                &normalized,
            )?
        } else {
            normalized.clone()
        };

        let mut context = ComponentDecodeContext::new(entity_map(self.world()));
        let mut edited = self.world().clone();
        let requirements = edited.component_registry.required_schemas(type_id)?;
        ensure_required_components(&mut edited, &requirements, entity)?;
        for other in &schema.incompatible_with {
            let incompatible = edited
                .component_registry
                .get(other)
                .map(|candidate| (candidate.has)(&edited, entity))
                == Some(true);
            if incompatible {
                return Err(ComponentEditError::IncompatibleComponent(other.clone()).into());
            }
        }
        (schema.apply_edit)(&data, entity, &mut context, &mut edited);
        if !(schema.has)(&edited, entity) {
            return Err(ComponentEditError::InvalidValue(type_id.to_string()).into());
        }
        let confirmed = component_data_in(&edited, &schema, entity);
        if confirmed
            .as_ref()
            .map(|value| value.contains_fields(&normalized))
            != Some(true)
        {
            return Err(ComponentEditError::InvalidValue(type_id.to_string()).into());
        }
        *self.world_mut() = edited;
        Ok(())
    }

    /// Installs a schema's default component and its dependencies.
    pub fn add_component(
        &mut self,
        type_id: &str,
        entity: EntityID,
    ) -> Result<(), ComponentEditFailure> {
        let schema = self
            .component_registry()
            .get(type_id)
            .cloned()
            .ok_or_else(|| ComponentEditError::UnknownType(type_id.to_string()))?;
        make_default_component(self.world_mut(), &schema, entity)
    }

    /// Removes one component, refusing when it is not present.
    pub fn remove_component_data(
        &mut self,
        type_id: &str,
        entity: EntityID,
    ) -> Result<(), ComponentEditFailure> {
        let schema = self
            .component_registry()
            .get(type_id)
            .cloned()
            .ok_or_else(|| ComponentEditError::UnknownType(type_id.to_string()))?;
        let world = self.world_mut();
        if !(schema.has)(world, entity) {
            return Err(ComponentEditError::MissingComponent(type_id.to_string()).into());
        }
        (schema.remove)(entity, world);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::document_schema::DocumentComponentSchema;
    use crate::components::core::registry::{ComponentCategory, ComponentRegistry};
    use crate::components::core::value::ComponentValue;
    use std::collections::BTreeMap;

    fn object(entries: [(&str, ComponentValue); 1]) -> ComponentValue {
        ComponentValue::Object(
            entries
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect::<BTreeMap<_, _>>(),
        )
    }

    fn runtime() -> SceneRuntime {
        let mut registry = ComponentRegistry::new();
        registry.register(DocumentComponentSchema::new(
            "mod.health",
            "Health",
            ComponentCategory::Gameplay,
            object([("amount", ComponentValue::Number(5.0))]),
        ));
        SceneRuntime::new(registry)
    }

    #[test]
    fn replacing_reads_back_the_written_document() {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        runtime
            .add_component("mod.health", entity)
            .expect("default installs");
        runtime
            .set_component_data(
                &object([("amount", ComponentValue::Number(9.0))]),
                "mod.health",
                entity,
                ComponentWriteMode::Replace,
            )
            .expect("replace");
        assert_eq!(
            runtime.component_data("mod.health", entity),
            Some(object([("amount", ComponentValue::Number(9.0))]))
        );
    }

    #[test]
    fn merge_without_a_previous_component_is_rejected() {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        assert_eq!(
            runtime.set_component_data(
                &object([("amount", ComponentValue::Number(1.0))]),
                "mod.health",
                entity,
                ComponentWriteMode::Merge,
            ),
            Err(ComponentEditFailure::Edit(
                ComponentEditError::MissingComponent("mod.health".to_string())
            ))
        );
    }

    #[test]
    fn unknown_type_ids_are_reported_by_every_entry_point() {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        let value = object([("amount", ComponentValue::Number(1.0))]);
        assert_eq!(
            runtime.set_component_data(&value, "missing", entity, ComponentWriteMode::Replace),
            Err(ComponentEditFailure::Edit(ComponentEditError::UnknownType(
                "missing".to_string()
            )))
        );
        assert_eq!(
            runtime.add_component("missing", entity),
            Err(ComponentEditFailure::Edit(ComponentEditError::UnknownType(
                "missing".to_string()
            )))
        );
        assert_eq!(
            runtime.remove_component_data("missing", entity),
            Err(ComponentEditFailure::Edit(ComponentEditError::UnknownType(
                "missing".to_string()
            )))
        );
        assert!(!runtime.has_component_by_type_id("missing", entity));
    }
}
