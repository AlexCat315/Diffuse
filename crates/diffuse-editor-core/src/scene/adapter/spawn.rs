//! `Editor/Sources/EditorCore/Scene/Adapter/Spawn.swift`.
//!
//! Ready-to-use entities exposed by the editor's Hierarchy create menu. These
//! templates map to SceneRuntime primitives so they work in a new project
//! before any assets have been imported.

/// Ready-to-use entities exposed by the editor's Hierarchy create menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorEntityTemplate {
    Empty,
    Cube,
    DirectionalLight,
    PointLight,
    SpotLight,
    Camera,
}

impl EditorEntityTemplate {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorEntityTemplate; 6] = [
        EditorEntityTemplate::Empty,
        EditorEntityTemplate::Cube,
        EditorEntityTemplate::DirectionalLight,
        EditorEntityTemplate::PointLight,
        EditorEntityTemplate::SpotLight,
        EditorEntityTemplate::Camera,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            EditorEntityTemplate::Empty => "empty",
            EditorEntityTemplate::Cube => "cube",
            EditorEntityTemplate::DirectionalLight => "directionalLight",
            EditorEntityTemplate::PointLight => "pointLight",
            EditorEntityTemplate::SpotLight => "spotLight",
            EditorEntityTemplate::Camera => "camera",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            EditorEntityTemplate::Empty => "Empty Entity",
            EditorEntityTemplate::Cube => "Cube",
            EditorEntityTemplate::DirectionalLight => "Directional Light",
            EditorEntityTemplate::PointLight => "Point Light",
            EditorEntityTemplate::SpotLight => "Spot Light",
            EditorEntityTemplate::Camera => "Camera",
        }
    }
}
