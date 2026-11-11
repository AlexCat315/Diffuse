//! Translation of
//! Editor/Sources/EditorUI/Panels/ScriptEditor/GutterNavigation.swift.

use diffuse_plugin::Uuid;

/// An external navigation request takes precedence over an older gutter action.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptGutterNavigation {
    pub external_id: Option<Uuid>,
    pub character_index: Option<usize>,
    pub id: Uuid,
}

impl Default for ScriptGutterNavigation {
    fn default() -> Self {
        Self::new()
    }
}

impl ScriptGutterNavigation {
    /// Swift's memberwise `init` with both options defaulting to `nil` and a
    /// freshly minted identity.
    pub fn new() -> Self {
        ScriptGutterNavigation {
            external_id: None,
            character_index: None,
            id: Uuid::new(),
        }
    }
}
