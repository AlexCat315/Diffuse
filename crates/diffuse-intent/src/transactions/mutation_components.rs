//! `SceneComponentKey` — the identity used by component edits and undo grouping.
//!
//! Two component edits are the same undo unit exactly when they share this key, so it is
//! `Ord`/`Hash` and its ordering is `(entity, typeID)`.

use serde::{Deserialize, Serialize};

/// Identifies one component on one entity.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct SceneComponentKey {
    pub entity_id: u64,
    pub type_id: String,
}

impl SceneComponentKey {
    pub fn new(entity_id: u64, type_id: impl Into<String>) -> Self {
        SceneComponentKey {
            entity_id,
            type_id: type_id.into(),
        }
    }
}

impl super::transaction_ir::SceneMutation {
    /// Optional values are omitted before constructing the component merge.
    pub fn component_fields(
        entity_id: u64,
        type_id: impl Into<String>,
        fields: impl IntoIterator<
            Item = (
                String,
                Option<diffuse_scene::components::core::value::ComponentValue>,
            ),
        >,
    ) -> Self {
        use diffuse_scene::components::core::value::ComponentValue;
        Self::SetComponentData {
            entity_id,
            type_id: type_id.into(),
            value: ComponentValue::Object(
                fields
                    .into_iter()
                    .filter_map(|(key, value)| value.map(|v| (key, v)))
                    .collect(),
            ),
            mode: diffuse_scene::components::editing::ComponentWriteMode::Merge,
        }
    }

    pub fn component_data<C: diffuse_scene::entity_id::RuntimeComponent>(
        entity_id: u64,
        type_id: impl Into<String>,
        component: C,
        registry: diffuse_scene::components::core::registry::ComponentRegistry,
    ) -> Self {
        use diffuse_scene::components::core::registry::{
            ComponentEncodeContext, ComponentEncodePurpose,
        };
        use diffuse_scene::components::editing::ComponentWriteMode;
        use diffuse_scene::runtime_world::RuntimeWorld;
        let type_id = type_id.into();
        let mut world = RuntimeWorld::new(registry.clone());
        let entity = world.create_entity();
        let _ = world.set_component(component, entity);
        let mut context = ComponentEncodeContext::new(std::collections::BTreeMap::new());
        context.purpose = ComponentEncodePurpose::GameSave;
        let value = registry
            .get(&type_id)
            .and_then(|schema| (schema.encode)(&world, entity, &mut context))
            .unwrap_or_else(|| panic!("Component codec unavailable: {type_id}"));
        Self::SetComponentData {
            entity_id,
            type_id,
            value,
            mode: ComponentWriteMode::Replace,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_order_by_entity_then_type() {
        let mut keys = vec![
            SceneComponentKey::new(2, "a"),
            SceneComponentKey::new(1, "b"),
            SceneComponentKey::new(1, "a"),
        ];
        keys.sort();
        assert_eq!(
            keys,
            vec![
                SceneComponentKey::new(1, "a"),
                SceneComponentKey::new(1, "b"),
                SceneComponentKey::new(2, "a"),
            ]
        );
    }

    #[test]
    fn the_same_component_on_two_entities_differs() {
        assert_ne!(
            SceneComponentKey::new(1, "a"),
            SceneComponentKey::new(2, "a")
        );
    }
}
