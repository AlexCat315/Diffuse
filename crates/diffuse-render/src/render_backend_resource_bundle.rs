//! Translation of RenderBackendResourceBundle.swift.
//!
//! Swift resolves `PackageResourceBundle.required(named: "DiffuseRuntime_RenderBackend")`
//! through the SwiftPM resource bundle; Rust resolves the same directory through
//! `cove_platform::ResourceBundle` beside the executable (Cove's own
//! `CoveUIComposeResourceBundle` pattern). The bundle holds the offline shader
//! artifacts (`Shaders/Native/…`), the fixture mesh and the GLTF scene.

use std::path::Path;
use std::sync::OnceLock;

use cove_platform::ResourceBundle;

/// The backend resource bundle. Resolution is lazy so a library-only consumer
/// never touches the filesystem until a shader or mesh is requested.
pub struct RenderBackendResourceBundle;

impl RenderBackendResourceBundle {
    /// Swift's `RenderBackendResourceBundle.bundle`. Missing roots are a
    /// deployment error, matching `PackageResourceBundle.required`.
    pub fn bundle() -> &'static ResourceBundle {
        static BUNDLE: OnceLock<ResourceBundle> = OnceLock::new();
        BUNDLE.get_or_init(|| {
            ResourceBundle::beside_executable(&[
                "DiffuseRuntime_RenderBackend",
                "DiffuseRuntime_RenderBackend.resources",
            ])
            .expect("failed to inspect RenderBackend resource bundle roots")
            .expect("could not locate the RenderBackend resource bundle")
        })
    }
}

/// Swift's `Bundle.url(forResource:withExtension:subdirectory:)` for this bundle.
pub fn url_for_resource(
    resource: &str,
    extension: &str,
    subdirectory: &str,
) -> Option<std::path::PathBuf> {
    let relative = Path::new(subdirectory).join(format!("{resource}.{extension}"));
    let root = RenderBackendResourceBundle::bundle().root();
    let candidate = root.join(&relative);
    candidate.is_file().then_some(candidate)
}
