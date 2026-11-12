//! Ported from `Editor/Tests/EditorCoreTests/EditorResourceBundleTests.swift`.

use cove_platform::ResourceBundle;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;

use crate::application::plugins::bundled::BundledPlugins;

fn editor_bundle() -> Option<ResourceBundle> {
    ResourceBundle::beside_executable(&[
        "DiffuseEditor_EditorCore",
        "DiffuseEditor_EditorCore.resources",
    ])
    .ok()
    .flatten()
}

/// The localization bundle resolves through the packaged resource locator.
#[test]
fn localization_bundle_resolves() {
    let Some(bundle) = editor_bundle() else {
        return;
    };
    assert!(bundle.root().join("en.lproj").exists());
}

/// Every packaged plugin loads from the resource bundle.
#[test]
fn packaged_plugins_load() {
    let Some(bundle) = editor_bundle() else {
        return;
    };
    let root = bundle.root().join("Plugins");
    let mut packages: Vec<std::path::PathBuf> = std::fs::read_dir(&root)
        .expect("plugin directory")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "coveplugin")
        })
        .collect();
    packages.sort();
    assert!(!packages.is_empty(), "No plugins in {}", root.display());
    let loader = PluginPackageLoader::new(
        CapabilityRegistry::default_registry(),
        None,
        ContributionPointRegistry::standard(),
    );
    for package in packages {
        let loaded = loader.load(&package).unwrap_or_else(|error| {
            panic!("Missing bundled plugin at {}: {error}", package.display())
        });
        assert!(
            BundledPlugins::plugin(&loaded.manifest.id).is_some(),
            "Missing bundled plugin at {}",
            package.display()
        );
    }
}
