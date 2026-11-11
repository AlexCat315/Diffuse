//! `Editor/Sources/EditorCore/Scene/Models/EditorSceneNode.swift`.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorSceneNode {
    pub id: u64,
    pub name: String,
    pub kind: String,
    pub children: Vec<EditorSceneNode>,
}

impl EditorSceneNode {
    pub fn new(
        id: u64,
        name: impl Into<String>,
        kind: impl Into<String>,
        children: Vec<EditorSceneNode>,
    ) -> Self {
        EditorSceneNode {
            id,
            name: name.into(),
            kind: kind.into(),
            children,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorSceneEntitySummary {
    pub id: u64,
    pub name: String,
    pub kind: String,
}

impl EditorSceneEntitySummary {
    pub fn new(id: u64, name: impl Into<String>, kind: impl Into<String>) -> Self {
        EditorSceneEntitySummary {
            id,
            name: name.into(),
            kind: kind.into(),
        }
    }
}
