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

impl EditorAppResourceBundle {
    /// The bundle when the executable ships beside one. String lookups fall
    /// back to their keys without it; asset callers still use [`Self::bundle`].
    pub fn bundle_if_available() -> Option<&'static ResourceBundle> {
        static BUNDLE: OnceLock<Option<ResourceBundle>> = OnceLock::new();
        BUNDLE
            .get_or_init(|| {
                ResourceBundle::beside_executable(&[
                    "DiffuseEditor_EditorUI",
                    "DiffuseEditor_EditorUI.resources",
                ])
                .ok()
                .flatten()
            })
            .as_ref()
    }
}
