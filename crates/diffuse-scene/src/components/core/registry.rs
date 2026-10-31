//! Component categories, schemas and the value-owned registry.
//!
//! ## The registry/world cycle
//!
//! Swift's `ComponentSchema` stores closures typed
//! `@Sendable (RuntimeWorld, EntityID) -> …` while `RuntimeWorld` holds a
//! `ComponentRegistry`. That is expressible in Rust because the closures are
//! non-capturing static functions whose `&RuntimeWorld` is a *parameter*, so the
//! registry is not generic over the world and neither type is recursive by value.
//! MIGRATION.md §5.2 prefers fn pointers over `Box<dyn Fn>` for exactly this case;
//! no closure here captures anything.
//!
//! ## `ObjectIdentifier` → [`ComponentTypeKey`]
//!
//! Swift identifies a schema's runtime type with `ObjectIdentifier`. Rust's `TypeId`
//! covers real component types, but data-declared components (plugin output) have no
//! Rust type at all — Swift invents identity with a private heap object.
//! [`ComponentTypeKey::Document`] carries a process-unique token for those.

use std::any::TypeId;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

use crate::components::core::value::{ComponentValue, ManifestComponent};
use crate::components::editing::ComponentEditError;
use crate::components::inspection::inspection::ComponentInspection;
use crate::entity_id::{EntityID, RuntimeComponent};
use crate::runtime_world::RuntimeWorld;

/// `ComponentCategory` — a `String`-backed `Codable` enum, so persisted values are
/// the case names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ComponentCategory {
    Rendering,
    Physics,
    Gameplay,
    Animation,
    Audio,
    Scripting,
    Assets,
}

impl ComponentCategory {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            ComponentCategory::Rendering => "rendering",
            ComponentCategory::Physics => "physics",
            ComponentCategory::Gameplay => "gameplay",
            ComponentCategory::Animation => "animation",
            ComponentCategory::Audio => "audio",
            ComponentCategory::Scripting => "scripting",
            ComponentCategory::Assets => "assets",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "rendering" => Some(ComponentCategory::Rendering),
            "physics" => Some(ComponentCategory::Physics),
            "gameplay" => Some(ComponentCategory::Gameplay),
            "animation" => Some(ComponentCategory::Animation),
            "audio" => Some(ComponentCategory::Audio),
            "scripting" => Some(ComponentCategory::Scripting),
            "assets" => Some(ComponentCategory::Assets),
            _ => None,
        }
    }

    pub const fn display_name(&self) -> &'static str {
        match self {
            ComponentCategory::Rendering => "Rendering",
            ComponentCategory::Physics => "Physics",
            ComponentCategory::Gameplay => "Gameplay",
            ComponentCategory::Animation => "Animation",
            ComponentCategory::Audio => "Audio",
            ComponentCategory::Scripting => "Scripting",
            ComponentCategory::Assets => "Assets",
        }
    }

    pub const ALL: [ComponentCategory; 7] = [
        ComponentCategory::Rendering,
        ComponentCategory::Physics,
        ComponentCategory::Gameplay,
        ComponentCategory::Animation,
        ComponentCategory::Audio,
        ComponentCategory::Scripting,
        ComponentCategory::Assets,
    ];
}

impl Serialize for ComponentCategory {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for ComponentCategory {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        ComponentCategory::from_raw_value(&value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown component category: {value}")))
    }
}

/// Identity of a schema's storage type.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ComponentTypeKey {
    Runtime(TypeId),
    /// A data-declared component has no Rust type; this token stands in for Swift's
    /// private `DocumentComponentIdentity` instance.
    Document(u64),
}

impl ComponentTypeKey {
    /// Allocates a process-unique document identity.
    pub fn new_document() -> ComponentTypeKey {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        ComponentTypeKey::Document(NEXT.fetch_add(1, Ordering::Relaxed))
    }

    pub fn of<C: RuntimeComponent>() -> ComponentTypeKey {
        ComponentTypeKey::Runtime(TypeId::of::<C>())
    }

    /// Same as [`Self::of`] but without the component bound, for resources (which
    /// are only `Send + Sync`, not ECS components).
    pub fn of_type<T: 'static>() -> ComponentTypeKey {
        ComponentTypeKey::Runtime(TypeId::of::<T>())
    }
}

/// Mirrors `ComponentEncodeContext.Purpose`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ComponentEncodePurpose {
    #[default]
    Authored,
    GameSave,
    Transaction,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ComponentEncodeContext {
    pub entity_index_map: BTreeMap<EntityID, i64>,
    pub purpose: ComponentEncodePurpose,
}

impl ComponentEncodeContext {
    pub fn new(entity_index_map: BTreeMap<EntityID, i64>) -> Self {
        ComponentEncodeContext {
            entity_index_map,
            purpose: ComponentEncodePurpose::Authored,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ComponentDecodeContext {
    pub entity_map: BTreeMap<i64, EntityID>,
}

impl ComponentDecodeContext {
    pub fn new(entity_map: BTreeMap<i64, EntityID>) -> Self {
        ComponentDecodeContext { entity_map }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ComponentDependencyError {
    #[error("unknown component: {0}")]
    UnknownComponent(String),
    #[error("missing requirement: {component} requires {required}")]
    MissingRequirement { component: String, required: String },
    #[error("cyclic requirement: {0:?}")]
    Cycle(Vec<String>),
    #[error("no default for component: {0}")]
    DefaultUnavailable(String),
}

type HasFn = fn(&RuntimeWorld, EntityID) -> bool;
type EncodeFn = fn(&RuntimeWorld, EntityID, &mut ComponentEncodeContext) -> Option<ComponentValue>;
type DecodeFn = fn(&ComponentValue, EntityID, &mut ComponentDecodeContext, &mut RuntimeWorld);
type AfterDuplicateFn = fn(EntityID, &mut RuntimeWorld);
type EditFn = fn(&ComponentValue, &ComponentValue) -> Result<ComponentValue, ComponentEditError>;
type MakeDefaultFn = fn(EntityID, &mut RuntimeWorld);
type RemoveFn = fn(EntityID, &mut RuntimeWorld);
type HasEntityFn = HasFn;

/// One component's persistence and authoring operations.
#[derive(Clone)]
pub struct ComponentSchema {
    pub component_type_id: ComponentTypeKey,
    pub runtime_type_name: String,
    pub type_id: String,
    pub display_name: String,
    pub category: ComponentCategory,
    pub requires: Vec<String>,
    pub incompatible_with: Vec<String>,
    pub is_user_addable: bool,
    /// Structural values are registered for dependencies but keep their existing
    /// document fields instead of appearing in the component payload dictionary.
    pub is_structural: bool,
    pub inspection: ComponentInspection,
    pub has: HasEntityFn,
    pub encode: EncodeFn,
    pub decode: DecodeFn,
    pub apply_edit: DecodeFn,
    pub after_duplicate: AfterDuplicateFn,
    /// Canonicalizes accepted partial input before merging and codec validation.
    /// Full replacement and disk decoding remain exact and bypass this hook.
    pub normalize_changes: Option<EditFn>,
    pub merge: EditFn,
    pub make_default: MakeDefaultFn,
    pub remove: RemoveFn,
}

impl std::fmt::Debug for ComponentSchema {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ComponentSchema")
            .field("type_id", &self.type_id)
            .field("runtime_type_name", &self.runtime_type_name)
            .field("category", &self.category)
            .field("requires", &self.requires)
            .field("is_structural", &self.is_structural)
            .finish()
    }
}

impl ComponentSchema {
    /// Swift's generic `init(_:typeID:displayName:category:encode:decode:makeDefault:configure:)`.
    /// `has` and `remove` are derived from the component store, matching Swift.
    #[allow(clippy::too_many_arguments)]
    pub fn for_component<C: RuntimeComponent>(
        type_id: impl Into<String>,
        display_name: impl Into<String>,
        category: ComponentCategory,
        encode: EncodeFn,
        decode: DecodeFn,
        make_default: MakeDefaultFn,
    ) -> Self {
        fn has<C: RuntimeComponent>(world: &RuntimeWorld, entity: EntityID) -> bool {
            world.has_component::<C>(entity)
        }
        fn remove<C: RuntimeComponent>(entity: EntityID, world: &mut RuntimeWorld) {
            let _ = world.remove_component::<C>(entity);
        }
        ComponentSchema {
            component_type_id: ComponentTypeKey::of::<C>(),
            runtime_type_name: std::any::type_name::<C>().to_string(),
            type_id: type_id.into(),
            display_name: display_name.into(),
            category,
            requires: Vec::new(),
            incompatible_with: Vec::new(),
            is_user_addable: true,
            is_structural: false,
            inspection: ComponentInspection::default(),
            has: has::<C>,
            encode,
            decode,
            apply_edit: decode,
            after_duplicate: |_, _| {},
            normalize_changes: None,
            merge: default_merge,
            make_default,
            remove: remove::<C>,
        }
    }

    /// A data-declared component: storage is the authored document itself.
    pub fn from_document(
        type_id: impl Into<String>,
        display_name: impl Into<String>,
        category: ComponentCategory,
        component_type_id: ComponentTypeKey,
    ) -> Self {
        fn has(world: &RuntimeWorld, entity: EntityID) -> bool {
            // The document type is captured by the caller through `make_default` and
            // friends; `has` only needs to know that *some* document exists, so it is
            // rebound by `bind_document_has`.
            let _ = (world, entity);
            false
        }
        ComponentSchema {
            component_type_id,
            runtime_type_name: String::new(),
            type_id: type_id.into(),
            display_name: display_name.into(),
            category,
            requires: Vec::new(),
            incompatible_with: Vec::new(),
            is_user_addable: true,
            is_structural: false,
            inspection: ComponentInspection::default(),
            has,
            encode: |_, _, _| None,
            decode: |_, _, _, _| {},
            apply_edit: |_, _, _, _| {},
            after_duplicate: |_, _| {},
            normalize_changes: None,
            merge: default_merge,
            make_default: |_, _| {},
            remove: |_, _| {},
        }
    }
}

/// Swift's default `merge` closure: `try $0.merging($1)`.
fn default_merge(
    previous: &ComponentValue,
    changes: &ComponentValue,
) -> Result<ComponentValue, ComponentEditError> {
    previous.merging(changes)
}

type RequirementPlan =
    BTreeMap<ComponentTypeKey, Result<Vec<ComponentSchema>, ComponentDependencyError>>;

/// A value-owned registry. A scene may add module codecs without changing other
/// scenes, tests, or concurrent serializers.
#[derive(Clone, Default)]
pub struct ComponentRegistry {
    pub schemas: Vec<ComponentSchema>,
    required_schemas_by_type: RequirementPlan,
}

impl std::fmt::Debug for ComponentRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ComponentRegistry")
            .field("schemas", &self.schemas)
            .finish()
    }
}

impl ComponentRegistry {
    pub fn new() -> Self {
        ComponentRegistry::default()
    }

    /// Duplicate IDs are programmer errors in Swift (`precondition`), so they panic.
    ///
    /// # Panics
    ///
    /// Panics on an empty or duplicate `type_id`, or a duplicate runtime type.
    pub fn register(&mut self, schema: ComponentSchema) {
        assert!(
            !schema.type_id.is_empty() && self.get(&schema.type_id).is_none(),
            "Duplicate or empty component type ID: {}",
            schema.type_id
        );
        assert!(
            !self
                .schemas
                .iter()
                .any(|existing| existing.component_type_id == schema.component_type_id),
            "Duplicate runtime component type: {}",
            schema.runtime_type_name
        );
        self.schemas.push(schema);
        // Forward declarations are allowed during registration. Rebuild plans so a
        // later registration can satisfy an earlier schema's requirements.
        let mut plan = RequirementPlan::new();
        for schema in &self.schemas {
            let resolved = self.resolve_requirements(schema);
            plan.insert(schema.component_type_id, resolved);
        }
        self.required_schemas_by_type = plan;
    }

    pub fn get(&self, type_id: &str) -> Option<&ComponentSchema> {
        self.schemas.iter().find(|schema| schema.type_id == type_id)
    }

    pub fn schema_for<C: RuntimeComponent>(&self) -> Option<&ComponentSchema> {
        let key = ComponentTypeKey::of::<C>();
        self.schemas
            .iter()
            .find(|schema| schema.component_type_id == key)
    }

    /// Non-structural schemas, in registration order.
    pub fn component_schemas(&self) -> Vec<ComponentSchema> {
        self.schemas
            .iter()
            .filter(|schema| !schema.is_structural)
            .cloned()
            .collect()
    }

    pub fn validate_requirements(&self) -> Result<(), ComponentDependencyError> {
        for schema in &self.schemas {
            self.required_schemas(&schema.type_id)?;
        }
        Ok(())
    }

    /// Dependencies in default-construction order, excluding the requested owner.
    pub fn required_schemas(
        &self,
        type_id: &str,
    ) -> Result<Vec<ComponentSchema>, ComponentDependencyError> {
        let schema = self
            .get(type_id)
            .ok_or_else(|| ComponentDependencyError::UnknownComponent(type_id.to_string()))?;
        match self.required_schemas_by_type.get(&schema.component_type_id) {
            Some(plan) => plan.clone(),
            None => self.resolve_requirements(schema),
        }
    }

    pub fn required_schemas_for<C: RuntimeComponent>(
        &self,
    ) -> Result<Vec<ComponentSchema>, ComponentDependencyError> {
        let key = ComponentTypeKey::of::<C>();
        match self.required_schemas_by_type.get(&key) {
            Some(plan) => plan.clone(),
            None => Ok(Vec::new()),
        }
    }

    /// Encodes every non-structural component on `entity`, in registration order.
    pub fn encode(
        &self,
        entity: EntityID,
        world: &RuntimeWorld,
        context: &mut ComponentEncodeContext,
    ) -> Vec<ManifestComponent> {
        let mut encoded = Vec::new();
        for schema in &self.schemas {
            if schema.is_structural {
                continue;
            }
            if let Some(value) = (schema.encode)(world, entity, context) {
                encoded.push(ManifestComponent::new(schema.type_id.clone(), value));
            }
        }
        encoded
    }

    /// Decodes explicitly authored dependencies before their owners, so an owner's
    /// required default cannot read a dependency's temporary default.
    pub fn decode(
        &self,
        components: &[ManifestComponent],
        entity: EntityID,
        context: &mut ComponentDecodeContext,
        world: &mut RuntimeWorld,
    ) {
        let values: BTreeMap<&str, &ComponentValue> = components
            .iter()
            .map(|component| (component.type_id.as_str(), &component.value))
            .collect();
        let mut decoded: Vec<String> = Vec::new();
        for schema in &self.schemas {
            if schema.is_structural {
                continue;
            }
            if !values.contains_key(schema.type_id.as_str()) {
                continue;
            }
            let requirements = self.required_schemas(&schema.type_id).unwrap_or_default();
            for candidate in requirements.iter().chain(std::iter::once(schema)) {
                if candidate.is_structural {
                    continue;
                }
                let Some(value) = values.get(candidate.type_id.as_str()) else {
                    continue;
                };
                if decoded.contains(&candidate.type_id) {
                    continue;
                }
                decoded.push(candidate.type_id.clone());
                (candidate.decode)(value, entity, context, world);
            }
        }
    }

    fn resolve_requirements(
        &self,
        root: &ComponentSchema,
    ) -> Result<Vec<ComponentSchema>, ComponentDependencyError> {
        fn visit(
            registry: &ComponentRegistry,
            schema: &ComponentSchema,
            root_type_id: &str,
            result: &mut Vec<ComponentSchema>,
            visited: &mut Vec<String>,
            path: &mut Vec<String>,
        ) -> Result<(), ComponentDependencyError> {
            if let Some(index) = path.iter().position(|entry| entry == &schema.type_id) {
                let mut cycle: Vec<String> = path[index..].to_vec();
                cycle.push(schema.type_id.clone());
                return Err(ComponentDependencyError::Cycle(cycle));
            }
            if visited.contains(&schema.type_id) {
                return Ok(());
            }
            path.push(schema.type_id.clone());
            for required_type_id in &schema.requires {
                let required = registry.get(required_type_id).ok_or_else(|| {
                    ComponentDependencyError::MissingRequirement {
                        component: schema.type_id.clone(),
                        required: required_type_id.clone(),
                    }
                })?;
                visit(registry, required, root_type_id, result, visited, path)?;
            }
            path.pop();
            visited.push(schema.type_id.clone());
            if schema.type_id != root_type_id {
                result.push(schema.clone());
            }
            Ok(())
        }

        let mut result = Vec::new();
        let mut visited = Vec::new();
        let mut path = Vec::new();
        visit(
            self,
            root,
            &root.type_id,
            &mut result,
            &mut visited,
            &mut path,
        )?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy(type_id: &str, requires: Vec<String>) -> ComponentSchema {
        let mut schema = ComponentSchema::from_document(
            type_id,
            type_id,
            ComponentCategory::Gameplay,
            ComponentTypeKey::new_document(),
        );
        schema.requires = requires;
        schema
    }

    #[test]
    fn category_round_trips() {
        for category in ComponentCategory::ALL {
            assert_eq!(
                ComponentCategory::from_raw_value(category.raw_value()),
                Some(category)
            );
        }
        assert_eq!(ComponentCategory::Assets.display_name(), "Assets");
    }

    #[test]
    fn document_keys_are_unique() {
        assert_ne!(
            ComponentTypeKey::new_document(),
            ComponentTypeKey::new_document()
        );
    }

    #[test]
    fn register_and_lookup_by_type_id() {
        let mut registry = ComponentRegistry::new();
        registry.register(dummy("mod.thing", Vec::new()));
        assert!(registry.get("mod.thing").is_some());
        assert!(registry.get("missing").is_none());
    }

    #[test]
    fn requirements_are_returned_in_dependency_order() {
        let mut registry = ComponentRegistry::new();
        registry.register(dummy("base", Vec::new()));
        registry.register(dummy("mid", vec!["base".to_string()]));
        registry.register(dummy("top", vec!["mid".to_string(), "base".to_string()]));
        let requirements = registry.required_schemas("top").expect("requirements");
        assert_eq!(
            requirements
                .iter()
                .map(|schema| schema.type_id.as_str())
                .collect::<Vec<_>>(),
            vec!["base", "mid"]
        );
    }

    #[test]
    fn missing_requirement_is_reported() {
        let mut registry = ComponentRegistry::new();
        registry.register(dummy("owner", vec!["absent".to_string()]));
        assert_eq!(
            registry.required_schemas("owner").err(),
            Some(ComponentDependencyError::MissingRequirement {
                component: "owner".to_string(),
                required: "absent".to_string(),
            })
        );
    }

    #[test]
    fn cycle_is_reported() {
        let mut registry = ComponentRegistry::new();
        registry.register(dummy("a", vec!["b".to_string()]));
        registry.register(dummy("b", vec!["a".to_string()]));
        match registry.required_schemas("a") {
            Err(ComponentDependencyError::Cycle(path)) => {
                assert!(path.len() >= 3, "cycle path should close: {path:?}");
            }
            other => panic!("expected a cycle, got {other:?}"),
        }
    }

    #[test]
    fn unknown_component_is_reported() {
        assert_eq!(
            ComponentRegistry::new().required_schemas("nope").err(),
            Some(ComponentDependencyError::UnknownComponent(
                "nope".to_string()
            ))
        );
    }

    #[test]
    fn later_registration_satisfies_earlier_forward_declaration() {
        let mut registry = ComponentRegistry::new();
        registry.register(dummy("owner", vec!["late".to_string()]));
        assert!(registry.required_schemas("owner").is_err());
        registry.register(dummy("late", Vec::new()));
        let requirements = registry.required_schemas("owner").expect("resolved");
        assert_eq!(requirements.len(), 1);
        assert_eq!(requirements[0].type_id, "late");
    }

    #[test]
    fn structural_schemas_are_excluded_from_payloads() {
        let mut registry = ComponentRegistry::new();
        let mut structural = dummy("localTransform", Vec::new());
        structural.is_structural = true;
        registry.register(structural);
        registry.register(dummy("collider", Vec::new()));
        let payloads: Vec<String> = registry
            .component_schemas()
            .into_iter()
            .map(|schema| schema.type_id)
            .collect();
        assert_eq!(payloads, vec!["collider".to_string()]);
    }

    #[test]
    fn duplicate_type_id_panics() {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut registry = ComponentRegistry::new();
            registry.register(dummy("dup", Vec::new()));
            registry.register(dummy("dup", Vec::new()));
        }));
        assert!(result.is_err());
    }
}
