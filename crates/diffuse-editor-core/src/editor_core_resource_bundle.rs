//! `Editor/Sources/EditorCore/EditorCoreResourceBundle.swift`.
//!
//! Swift resolved `PackageResourceBundle.required(named: "DiffuseEditor_EditorCore")`
//! through the SwiftPM resource bundle; Rust resolves the same directory beside
//! the executable, following Cove's `CoveUIComposeResourceBundle` pattern. It
//! holds `Plugins/` (the bundled `.coveplugin` packages) and the localization
//! tables.

use std::sync::OnceLock;

use cove_platform::ResourceBundle;

pub struct EditorCoreResourceBundle;

impl EditorCoreResourceBundle {
    /// Swift's `EditorCoreResourceBundle.bundle`. Missing roots are a deployment
    /// error, matching `PackageResourceBundle.required`.
    pub fn bundle() -> &'static ResourceBundle {
        static BUNDLE: OnceLock<ResourceBundle> = OnceLock::new();
        BUNDLE.get_or_init(|| {
            ResourceBundle::beside_executable(&[
                "DiffuseEditor_EditorCore",
                "DiffuseEditor_EditorCore.resources",
            ])
            .expect("failed to inspect EditorCore resource bundle roots")
            .expect("could not locate the EditorCore resource bundle")
        })
    }
}
