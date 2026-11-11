//! `Editor/Sources/EditorCore/Scene/Manifest/Node.swift`.

use diffuse_scene::components::core::value::ManifestComponent;
use serde::{Deserialize, Serialize};

use crate::scene::manifest::transform_math::EditorSceneManifestMatrix;

/// Scene nodes keep hierarchy and editor identity; every authored component uses
/// the runtime registry's document value and relocatable reference indices.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifestNode {
    pub id: u64,
    pub name: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_transform: Option<EditorSceneManifestMatrix>,
    #[serde(default)]
    pub components: Vec<ManifestComponent>,
    #[serde(default)]
    pub children: Vec<EditorSceneManifestNode>,
}

impl EditorSceneManifestNode {
    /// Swift's memberwise initializer with its empty-collection defaults.
    pub fn new(id: u64, name: impl Into<String>, kind: impl Into<String>) -> Self {
        EditorSceneManifestNode {
            id,
            name: name.into(),
            kind: kind.into(),
            local_transform: None,
            components: Vec::new(),
            children: Vec::new(),
        }
    }

    /// The full memberwise initializer.
    pub fn with_options(
        id: u64,
        name: impl Into<String>,
        kind: impl Into<String>,
        local_transform: Option<EditorSceneManifestMatrix>,
        components: Vec<ManifestComponent>,
        children: Vec<EditorSceneManifestNode>,
    ) -> Self {
        EditorSceneManifestNode {
            id,
            name: name.into(),
            kind: kind.into(),
            local_transform,
            components,
            children,
        }
    }
}
