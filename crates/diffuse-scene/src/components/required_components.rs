//! `Components/RequiredComponents.swift` — dependency installation for component
//! edits.
//!
//! Swift declares `ComponentDependencyError` here and adds the two `RuntimeWorld`
//! methods as an extension. The error enum lives in
//! [`crate::components::core::registry`] because the registry's requirement plans
//! use it, and is re-exported below under its Swift home. `RuntimeWorld.swift` also
//! carries its own copies of the two methods (translated with that file); the
//! faithful versions are free functions taking the world explicitly, because Rust
//! forbids two inherent methods with the same name and these signatures keep
//! Swift's untyped `throws` surface intact.
//!
//! Both entry points are transactional: a failure leaves no partial components and
//! no revision increments behind, because they work on a copy of the world.

use std::collections::BTreeSet;

use thiserror::Error;

use crate::components::core::registry::ComponentSchema;
use crate::components::editing::ComponentEditError;
use crate::entity_id::EntityID;
use crate::runtime_world::RuntimeWorld;

/// Swift's declaration site for the dependency error domain.
pub use crate::components::core::registry::ComponentDependencyError;

/// The untyped `throws` surface of the component editing entry points.
///
/// Swift declares `throws` without a type, so a single call can raise both the edit
/// domain (`ComponentEditError`) and the dependency domain
/// (`ComponentDependencyError`). Rust callers match on this union.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum ComponentEditFailure {
    #[error(transparent)]
    Edit(#[from] ComponentEditError),
    #[error(transparent)]
    Dependency(#[from] ComponentDependencyError),
}

impl ComponentEditFailure {
    /// The edit-domain error, when this failure came from it.
    pub fn edit_error(&self) -> Option<&ComponentEditError> {
        match self {
            ComponentEditFailure::Edit(error) => Some(error),
            ComponentEditFailure::Dependency(_) => None,
        }
    }

    /// The dependency-domain error, when this failure came from it.
    pub fn dependency_error(&self) -> Option<&ComponentDependencyError> {
        match self {
            ComponentEditFailure::Dependency(error) => Some(error),
            ComponentEditFailure::Edit(_) => None,
        }
    }
}

/// Dependencies are insertion defaults: removing their owner leaves them in
/// place, and inserting an owner never overwrites an existing dependency.
pub fn ensure_required_components(
    world: &mut RuntimeWorld,
    requirements: &[ComponentSchema],
    entity: EntityID,
) -> Result<(), ComponentEditFailure> {
    let required_ids: BTreeSet<&str> = requirements
        .iter()
        .map(|schema| schema.type_id.as_str())
        .collect();
    for schema in requirements {
        for other in &schema.incompatible_with {
            let present = required_ids.contains(other.as_str())
                || world
                    .component_registry
                    .get(other)
                    .map(|candidate| (candidate.has)(world, entity))
                    == Some(true);
            if present {
                return Err(ComponentEditFailure::Edit(
                    ComponentEditError::IncompatibleComponent(other.clone()),
                ));
            }
        }
    }
    for schema in requirements {
        if (schema.has)(world, entity) {
            continue;
        }
        (schema.make_default)(entity, world);
        if !(schema.has)(world, entity) {
            return Err(ComponentEditFailure::Dependency(
                ComponentDependencyError::DefaultUnavailable(schema.type_id.clone()),
            ));
        }
    }
    Ok(())
}

/// Used by registry authoring flows so dependency failures leave no partial
/// components or revision increments behind.
pub fn make_default_component(
    world: &mut RuntimeWorld,
    schema: &ComponentSchema,
    entity: EntityID,
) -> Result<(), ComponentEditFailure> {
    if (schema.has)(world, entity) {
        return Ok(());
    }
    let mut edited = world.clone();
    let requirements = edited
        .component_registry
        .required_schemas(&schema.type_id)?;
    ensure_required_components(&mut edited, &requirements, entity)?;
    for other in &schema.incompatible_with {
        let incompatible = edited
            .component_registry
            .get(other)
            .map(|candidate| (candidate.has)(&edited, entity))
            == Some(true);
        if incompatible {
            return Err(ComponentEditFailure::Edit(
                ComponentEditError::IncompatibleComponent(other.clone()),
            ));
        }
    }
    (schema.make_default)(entity, &mut edited);
    if !(schema.has)(&edited, entity) {
        return Err(ComponentEditFailure::Dependency(
            ComponentDependencyError::DefaultUnavailable(schema.type_id.clone()),
        ));
    }
    *world = edited;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::document_schema::DocumentComponentSchema;
    use crate::components::core::registry::{
        ComponentCategory, ComponentRegistry, ComponentTypeKey,
    };
    use crate::components::core::value::ComponentValue;

    fn no_default_schema(type_id: &str) -> ComponentSchema {
        ComponentSchema::from_document(
            type_id,
            type_id,
            ComponentCategory::Gameplay,
            ComponentTypeKey::new_document(),
        )
    }

    #[test]
    fn a_missing_default_does_not_touch_the_world() {
        let mut world = RuntimeWorld::new(ComponentRegistry::new());
        let schema = no_default_schema("mod.empty");
        let mut registry = ComponentRegistry::new();
        registry.register(schema.clone());
        world.component_registry = registry;
        let entity = world.create_entity();
        assert_eq!(
            make_default_component(&mut world, &schema, entity),
            Err(ComponentEditFailure::Dependency(
                ComponentDependencyError::DefaultUnavailable("mod.empty".to_string())
            ))
        );
        assert!(!(schema.has)(&world, entity));
    }

    #[test]
    fn an_incompatible_present_component_is_reported() {
        let mut registry = ComponentRegistry::new();
        registry.register(DocumentComponentSchema::new(
            "mod.a",
            "A",
            ComponentCategory::Gameplay,
            ComponentValue::Object(Default::default()),
        ));
        let mut world = RuntimeWorld::new(registry);
        let entity = world.create_entity();
        let a = world
            .component_registry
            .get("mod.a")
            .cloned()
            .expect("mod.a");
        (a.make_default)(entity, &mut world);

        let mut owner = no_default_schema("owner");
        owner.incompatible_with = vec!["mod.a".to_string()];
        let mut registry = world.component_registry.clone();
        registry.register(owner.clone());
        world.component_registry = registry;

        assert_eq!(
            make_default_component(&mut world, &owner, entity),
            Err(ComponentEditFailure::Edit(
                ComponentEditError::IncompatibleComponent("mod.a".to_string())
            ))
        );
    }
}
