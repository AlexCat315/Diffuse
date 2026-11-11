//! Translation of Editor/Sources/EditorUI/ResourcesSupport.swift.

use std::sync::OnceLock;

use cove_platform::ResourceBundle;

pub struct EditorAppResourceBundle;

impl EditorAppResourceBundle {
    /// Swift's `PackageResourceBundle.required(named: "DiffuseEditor_EditorUI")`;
    /// Rust resolves the same directory beside the executable.
    pub fn bundle() -> &'static ResourceBundle {
        static BUNDLE: OnceLock<ResourceBundle> = OnceLock::new();
        BUNDLE.get_or_init(|| {
            ResourceBundle::beside_executable(&[
                "DiffuseEditor_EditorUI",
                "DiffuseEditor_EditorUI.resources",
            ])
            .expect("failed to inspect EditorUI resource bundle roots")
            .expect("could not locate the EditorUI resource bundle")
        })
    }
}
