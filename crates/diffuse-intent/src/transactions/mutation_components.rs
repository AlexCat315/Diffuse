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
