//! `Prefab` — a reusable entity template captured from a scene subtree.
//!
//! A prefab is the same relocatable JSON document `SceneSerializer` produces, so it
//! round-trips to disk as an asset and can be instantiated any number of times into
//! any scene. Entity cross-references inside the document are indices, so a captured
//! subtree never leaks a reference to the scene it came from.

use thiserror::Error;

use crate::entity_id::EntityID;
use crate::physics::destruction::{DestructibleFragment, DestructibleRetainedFragment};
use crate::runtime_world::{LocalTransform, RuntimeWorld};
use crate::serialization::scene_serializer::{
    PREFAB_VERSION, SceneSerializer, SceneSerializerError,
};

/// Failures raised while capturing or instantiating a prefab.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum PrefabError {
    #[error(transparent)]
    Scene(#[from] SceneSerializerError),
}

/// A reusable entity template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prefab {
    /// Serialized subtree. Entity 0 is always the prefab root; `parent`
    /// cross-references stay inside the subtree, so the captured root has no parent
    /// of its own.
    data: String,
}

impl Prefab {
    #[inline]
    pub fn new(data: impl Into<String>) -> Self {
        Prefab { data: data.into() }
    }

    #[inline]
    pub fn data(&self) -> &str {
        &self.data
    }

    /// Captures the subtree rooted at `root` (root plus descendants, depth-first).
    ///
    /// Returns `Ok(None)` when `root` is absent from `world` or is a runtime
    /// destruction fragment — fragments are runtime artefacts, not authored content.
    pub fn capture(world: &RuntimeWorld, root: EntityID) -> Result<Option<Prefab>, PrefabError> {
        if !world.contains(root)
            || world.component::<DestructibleFragment>(root).is_some()
            || world
                .component::<DestructibleRetainedFragment>(root)
                .is_some()
        {
            return Ok(None);
        }

        let mut ordered: Vec<EntityID> = Vec::new();
        fn visit(world: &RuntimeWorld, entity: EntityID, ordered: &mut Vec<EntityID>) {
            // A fragment anywhere in the subtree is skipped along with its children:
            // it has no authored representation.
            if world.component::<DestructibleFragment>(entity).is_some()
                || world
                    .component::<DestructibleRetainedFragment>(entity)
                    .is_some()
            {
                return;
            }
            ordered.push(entity);
            for child in world.children(entity) {
                visit(world, child, ordered);
            }
        }
        visit(world, root, &mut ordered);

        let index_map: std::collections::BTreeMap<EntityID, i64> = ordered
            .iter()
            .enumerate()
            .map(|(index, entity)| (*entity, index as i64))
            .collect();

        // Cross-references (parent, constraint endpoints) outside the captured
        // subtree disappear because they are absent from `index_map`.
        let entities: Vec<_> = ordered
            .iter()
            .map(|entity| {
                SceneSerializer::encode_entity(
                    world,
                    *entity,
                    &index_map,
                    crate::components::core::registry::ComponentEncodePurpose::Authored,
                )
            })
            .collect();

        let document = crate::serialization::scene_serializer::SceneDocument {
            version: PREFAB_VERSION,
            entities,
        };
        Ok(Some(Prefab::new(
            crate::serialization::scene_serializer::to_sorted_pretty(&document),
        )))
    }

    /// Instantiates the prefab into `world`, returning the new root entity (or
    /// `None` when the prefab is empty). `parent` attaches the new root beneath it;
    /// `transform` overrides the captured root transform (Unity-style placement).
    pub fn instantiate(
        &self,
        world: &mut RuntimeWorld,
        parent: Option<EntityID>,
        transform: Option<LocalTransform>,
    ) -> Result<Option<EntityID>, PrefabError> {
        Ok(self
            .instantiate_entities(world, parent, transform)?
            .first()
            .copied())
    }

    /// Instantiates the prefab and returns every created entity in document order,
    /// which is the mapping higher-level component serializers use.
    pub fn instantiate_entities(
        &self,
        world: &mut RuntimeWorld,
        parent: Option<EntityID>,
        transform: Option<LocalTransform>,
    ) -> Result<Vec<EntityID>, PrefabError> {
        // Mirror Swift's preconditions: the document must parse, contain an entity
        // array of objects, and (when given) the parent must exist.
        let value: serde_json::Value =
            serde_json::from_str(&self.data).map_err(|_| SceneSerializerError::InvalidFormat)?;
        let entities = value
            .get("entities")
            .and_then(serde_json::Value::as_array)
            .ok_or(SceneSerializerError::InvalidFormat)?;
        if !entities.iter().all(serde_json::Value::is_object) {
            return Err(SceneSerializerError::InvalidFormat.into());
        }
        if let Some(parent) = parent
            && !world.contains(parent)
        {
            return Err(SceneSerializerError::InvalidFormat.into());
        }
        let version = value
            .get("version")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0);
        if version != PREFAB_VERSION {
            return Err(SceneSerializerError::UnsupportedVersion(version).into());
        }

        let created = SceneSerializer::load_entities(entities, world, false);
        let Some(&root) = created.first() else {
            return Ok(Vec::new());
        };
        if let Some(transform) = transform {
            world.set_local_transform(transform, root);
        }
        if let Some(parent) = parent {
            world.set_parent(Some(parent), root);
        }
        Ok(created)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use crate::scene_bootstrap::SceneNameComponent;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn capturing_a_missing_root_returns_none() {
        let world = empty_world();
        let absent = EntityID::new(99, 0);
        assert_eq!(Prefab::capture(&world, absent).expect("capture"), None);
    }

    #[test]
    fn capture_then_instantiate_reproduces_the_subtree() {
        let mut world = empty_world();
        let root = world.create_entity();
        world.set_component(SceneNameComponent::new("root"), root);
        let child = world.create_entity();
        world.set_component(SceneNameComponent::new("child"), child);
        world.set_parent(Some(root), child);

        let prefab = Prefab::capture(&world, root)
            .expect("capture")
            .expect("non-empty");
        // The captured document is self-contained: the root has no parent.
        assert!(
            !prefab.data().contains("\"parent\" : -"),
            "root must not carry a parent"
        );

        let mut target = empty_world();
        let created = prefab
            .instantiate_entities(&mut target, None, None)
            .expect("instantiate");
        assert_eq!(created.len(), 2, "root plus one child");
        assert_eq!(
            target
                .component::<SceneNameComponent>(created[0])
                .map(|name| name.value.clone()),
            Some("root".to_string())
        );
        assert_eq!(target.parent(created[1]), Some(created[0]));
    }

    #[test]
    fn instantiate_returns_the_root() {
        let mut world = empty_world();
        let root = world.create_entity();
        world.set_component(SceneNameComponent::new("only"), root);

        let prefab = Prefab::capture(&world, root)
            .expect("capture")
            .expect("prefab");
        let mut target = empty_world();
        let created = prefab
            .instantiate(&mut target, None, None)
            .expect("instantiate");
        assert!(created.is_some(), "a non-empty prefab must yield a root");
    }

    #[test]
    fn instantiate_rejects_an_unsupported_version() {
        let prefab = Prefab::new("{\"version\":99,\"entities\":[]}");
        let mut world = empty_world();
        let error = prefab
            .instantiate(&mut world, None, None)
            .expect_err("must reject");
        assert_eq!(
            error,
            PrefabError::Scene(SceneSerializerError::UnsupportedVersion(99))
        );
    }

    #[test]
    fn instantiate_rejects_a_missing_parent() {
        let mut world = empty_world();
        let root = world.create_entity();
        world.set_component(SceneNameComponent::new("only"), root);
        let prefab = Prefab::capture(&world, root)
            .expect("capture")
            .expect("prefab");

        let mut target = empty_world();
        let absent = EntityID::new(42, 0);
        let error = prefab
            .instantiate(&mut target, Some(absent), None)
            .expect_err("must reject");
        assert_eq!(
            error,
            PrefabError::Scene(SceneSerializerError::InvalidFormat)
        );
    }

    #[test]
    fn an_empty_prefab_instantiates_to_nothing() {
        let prefab = Prefab::new("{\"version\":3,\"entities\":[]}");
        let mut world = empty_world();
        assert_eq!(
            prefab
                .instantiate_entities(&mut world, None, None)
                .expect("ok"),
            Vec::new()
        );
    }
}
