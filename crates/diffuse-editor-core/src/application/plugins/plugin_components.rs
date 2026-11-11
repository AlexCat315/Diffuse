//! Translation of Editor/Sources/EditorCore/Application/Plugins/PluginComponents.swift.
//!
//! Component declarations contributed by enabled plugins.
//!
//! A plugin declares components as serialized `ComponentDescription` values, so
//! the host owns storage, serialization, the generated inspector form and the
//! AI/MCP schema. Registrations are session state: they are not serialized with
//! the scene, and disabling a plugin withdraws them from new scenes.

use std::collections::BTreeMap;
use std::sync::Mutex;

use diffuse_scene::components::core::declarations::{
    ComponentDeclarationError, ComponentDeclarationLimits, ComponentDeclarations,
};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::inspection::inspection::ComponentDescription;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::interop::component_registry_script_codec::ComponentRegistryScriptCodec;

pub struct PluginComponentStore {
    declarations: Mutex<BTreeMap<String, Vec<ComponentDescription>>>,
}

impl Default for PluginComponentStore {
    fn default() -> Self {
        Self::new()
    }
}

impl PluginComponentStore {
    pub fn new() -> Self {
        PluginComponentStore {
            declarations: Mutex::new(BTreeMap::new()),
        }
    }

    fn declarations(
        &self,
    ) -> std::sync::MutexGuard<'_, BTreeMap<String, Vec<ComponentDescription>>> {
        self.declarations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn is_empty(&self) -> bool {
        self.declarations().is_empty()
    }

    pub fn set(&self, descriptions: Vec<ComponentDescription>, plugin_id: &str) {
        self.declarations()
            .insert(plugin_id.to_string(), descriptions);
    }

    pub fn remove(&self, plugin_id: &str) {
        let _ = self.declarations().remove(plugin_id);
    }

    pub fn remove_all(&self) {
        self.declarations().clear();
    }

    /// A fresh registry carrying built-ins plus every declaration. Callers own the
    /// copy: registering later declarations does not mutate scenes built earlier.
    pub fn registry(&self) -> ComponentRegistry {
        let installed = self.declarations().clone();
        let mut registry = ComponentRegistry::built_in();
        registry.register_script_codec("cove.rotator");
        for plugin_id in installed.keys() {
            // Declarations were validated when the plugin was enabled.
            let _ = registry
                .register_contents_of(installed.get(plugin_id).map(Vec::as_slice).unwrap_or(&[]));
        }
        registry
    }

    /// Withdraws and re-installs declarations on a live scene. Entities keep their
    /// authored documents; a withdrawn component simply stops being serialized.
    pub fn apply(&self, scene: &mut SceneRuntime) {
        scene.set_component_registry(self.registry());
    }
}

/// Decodes the `components` capability payload of one plugin.
pub struct PluginComponentDeclaration;

impl PluginComponentDeclaration {
    pub fn decode(payload: &[u8]) -> Result<Vec<ComponentDescription>, ComponentDeclarationError> {
        ComponentDeclarations::decode(payload, &ComponentDeclarationLimits::new())
    }
}
