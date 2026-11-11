//! `Editor/Sources/EditorCore/Scene/Adapter/Scripts.swift`.

use std::collections::BTreeSet;

use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_script::core::script_component::ScriptBinding;
use diffuse_script::interop::component_registry_script_codec::{
    ScriptAuthoringDefaults, encode_script_binding_for_editing,
};
use diffuse_script::{ScriptComponent, ScriptRuntime};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::EditorInspectorStringOption;
use crate::scripting::dynamic::project_script_catalog::{
    ProjectScriptCatalog, ProjectScriptCatalogEntry,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorScriptCatalogApplyReport {
    pub registered_script_count: i64,
    pub project_script_count: i64,
    pub unresolved_bindings: Vec<String>,
}

impl EditorSceneAdapter {
    pub fn apply_project_script_catalog(
        &self,
        catalog: &ProjectScriptCatalog,
    ) -> EditorScriptCatalogApplyReport {
        let next_identifiers: BTreeSet<String> = catalog
            .entries
            .iter()
            .map(|entry| entry.identifier.clone())
            .collect();
        let stale: Vec<String> = self
            .managed_script_identifiers
            .borrow()
            .difference(&next_identifiers)
            .cloned()
            .collect();
        for identifier in stale {
            self.script_runtime.unregister_named(&identifier);
        }
        for entry in &catalog.entries {
            self.script_runtime.register_preset(
                entry.preset,
                &entry.identifier,
                &entry.default_parameters_json,
            );
        }
        *self.managed_script_identifiers.borrow_mut() = next_identifiers;
        let mut entries: Vec<ProjectScriptCatalogEntry> = catalog.entries.clone();
        entries.sort_by(|lhs, rhs| {
            if lhs.is_built_in != rhs.is_built_in {
                return rhs.is_built_in.cmp(&lhs.is_built_in);
            }
            lhs.display_name
                .to_lowercase()
                .cmp(&rhs.display_name.to_lowercase())
        });
        let registered_script_count = entries.len() as i64;
        let project_script_count = entries.iter().filter(|entry| !entry.is_built_in).count() as i64;
        *self.script_catalog_entries.borrow_mut() = entries;

        EditorScriptCatalogApplyReport {
            registered_script_count,
            project_script_count,
            unresolved_bindings: self.unresolved_script_binding_descriptions(false),
        }
    }

    pub fn available_script_options(&self) -> Vec<EditorInspectorStringOption> {
        let catalog_entries = self.script_catalog_entries.borrow().clone();
        let catalog_options: Vec<EditorInspectorStringOption> = catalog_entries
            .iter()
            .map(|entry| {
                let suffix = if entry.is_built_in { "" } else { " · Project" };
                EditorInspectorStringOption::new(
                    entry.identifier.clone(),
                    format!("{}{suffix}", entry.display_name),
                )
            })
            .collect();
        let catalog_identifiers: BTreeSet<String> = catalog_options
            .iter()
            .map(|option| option.value.clone())
            .collect();
        let mut dynamic_options: Vec<EditorInspectorStringOption> = self
            .dynamic_script_display_names
            .borrow()
            .iter()
            .filter(|(identifier, _)| !catalog_identifiers.contains(*identifier))
            .map(|(identifier, display_name)| {
                EditorInspectorStringOption::new(
                    identifier.clone(),
                    format!("{display_name} · Swift"),
                )
            })
            .collect();
        dynamic_options.sort_by(|lhs, rhs| lhs.label.to_lowercase().cmp(&rhs.label.to_lowercase()));
        [catalog_options, dynamic_options].concat()
    }

    pub fn register_dynamic_script_option(
        &self,
        identifier: impl Into<String>,
        display_name: impl Into<String>,
        legacy_identifiers: &[String],
    ) {
        let identifier = identifier.into();
        self.dynamic_script_display_names
            .borrow_mut()
            .insert(identifier.clone(), display_name.into());
        let mut aliases = self.dynamic_script_aliases.borrow_mut();
        for alias in legacy_identifiers {
            aliases.insert(alias.clone(), identifier.clone());
        }
    }

    pub fn unregister_dynamic_script_option(&self, identifier: &str) {
        self.dynamic_script_display_names
            .borrow_mut()
            .remove(identifier);
        self.dynamic_script_aliases
            .borrow_mut()
            .retain(|_, value| value != identifier);
    }

    pub fn set_dynamic_script_options(
        &self,
        options: std::collections::BTreeMap<String, String>,
        aliases: std::collections::BTreeMap<String, String>,
    ) {
        *self.dynamic_script_display_names.borrow_mut() = options;
        *self.dynamic_script_aliases.borrow_mut() = aliases
            .into_iter()
            .filter(|(_, value)| {
                self.dynamic_script_display_names
                    .borrow()
                    .contains_key(value)
            })
            .collect();
    }

    pub(crate) fn dynamic_script_source_identifier(&self, identifier: &str) -> Option<String> {
        let canonical = self
            .dynamic_script_aliases
            .borrow()
            .get(identifier)
            .cloned()
            .unwrap_or_else(|| identifier.to_string());
        self.dynamic_script_display_names
            .borrow()
            .contains_key(&canonical)
            .then_some(canonical)
    }

    pub fn is_script_identifier_available(&self, identifier: &str) -> bool {
        self.script_runtime.handle(identifier).is_some()
    }

    /// Swift's `identifier: String? = nil` default.
    pub fn add_script_binding(&self, raw_id: u64) -> bool {
        self.add_script_binding_with_identifier(raw_id, None)
    }

    pub fn add_script_binding_with_identifier(
        &self,
        raw_id: u64,
        identifier: Option<&str>,
    ) -> bool {
        if !self.is_authoring_enabled() || self.is_entity_locked(raw_id) {
            return false;
        }
        let Some(entity) = self.script_entity(raw_id) else {
            return false;
        };
        let mut bindings = self
            .scene()
            .component::<ScriptComponent>(entity)
            .map(|component| component.bindings)
            .unwrap_or_default();
        let binding_identifier = identifier
            .map(str::to_string)
            .unwrap_or_else(|| self.default_script_identifier());
        bindings.push(ScriptBinding::with_identifier(binding_identifier));
        self.apply_scene_transaction(
            "scene.add_script_binding",
            "Add script binding",
            vec![raw_id],
            vec![SceneMutation::SetComponentData {
                entity_id: raw_id,
                type_id: "script".to_string(),
                value: bindings_component_value(&bindings),
                mode: diffuse_scene::components::editing::ComponentWriteMode::Replace,
            }],
        )
        .is_some()
    }

    pub fn remove_script_binding(&self, raw_id: u64, index: usize) -> bool {
        if !self.is_authoring_enabled() || self.is_entity_locked(raw_id) {
            return false;
        }
        let Some(entity) = self.script_entity(raw_id) else {
            return false;
        };
        let Some(mut bindings) = self
            .scene()
            .component::<ScriptComponent>(entity)
            .map(|component| component.bindings)
        else {
            return false;
        };
        if index >= bindings.len() {
            return false;
        }
        bindings.remove(index);
        self.apply_scene_transaction(
            "scene.remove_script_binding",
            "Remove script binding",
            vec![raw_id],
            vec![SceneMutation::SetComponentData {
                entity_id: raw_id,
                type_id: "script".to_string(),
                value: bindings_component_value(&bindings),
                mode: diffuse_scene::components::editing::ComponentWriteMode::Replace,
            }],
        )
        .is_some()
    }

    pub(crate) fn default_script_identifier(&self) -> String {
        if self.script_runtime.handle("cove.rotator").is_some() {
            return "cove.rotator".to_string();
        }
        self.script_catalog_entries
            .borrow()
            .first()
            .map(|entry| entry.identifier.clone())
            .unwrap_or_else(|| "cove.rotator".to_string())
    }

    /// Swift's `onlyEnabled: Bool = false` default.
    pub fn unresolved_script_binding_descriptions_default(&self) -> Vec<String> {
        self.unresolved_script_binding_descriptions(false)
    }

    pub fn unresolved_script_binding_descriptions(&self, only_enabled: bool) -> Vec<String> {
        let scene = self.scene();
        let mut descriptions: Vec<String> = Vec::new();
        for entity in scene.entities_with::<ScriptComponent>() {
            let Some(bindings) = scene
                .component::<ScriptComponent>(entity)
                .map(|component| component.bindings)
            else {
                continue;
            };
            let entity_name = scene
                .component::<SceneNameComponent>(entity)
                .map(|component| component.value)
                .unwrap_or_else(|| format!("Entity {}", entity.index));
            for (index, binding) in bindings.iter().enumerate() {
                if only_enabled && !binding.is_enabled {
                    continue;
                }
                if self.script_runtime.can_resolve(binding) {
                    continue;
                }
                let reference = binding
                    .identifier
                    .clone()
                    .unwrap_or_else(|| format!("handle #{}", binding.script.raw_value));
                descriptions.push(format!(
                    "{} · binding {}: {}",
                    entity_name,
                    index + 1,
                    reference
                ));
            }
        }
        descriptions
    }

    fn script_entity(&self, raw_id: u64) -> Option<EntityID> {
        let entity = EntityID::from_raw_value(raw_id);
        self.scene().contains(entity).then_some(entity)
    }

    /// Swift's `scene.setResource(ScriptAuthoringDefaults(identifier:))`.
    pub(crate) fn install_script_authoring_defaults(&self) {
        let identifier = self.default_script_identifier();
        self.with_scene_mut(|scene| {
            scene.set_resource(ScriptAuthoringDefaults::new(identifier));
        });
    }

    /// Keeps `ScriptRuntime` in the module's public surface for adapters that
    /// name it directly.
    pub fn script_runtime_ref(&self) -> &ScriptRuntime {
        &self.script_runtime
    }
}

fn bindings_component_value(bindings: &[ScriptBinding]) -> ComponentValue {
    ComponentValue::Object(std::collections::BTreeMap::from([(
        "bindings".to_string(),
        ComponentValue::Array(
            bindings
                .iter()
                .map(|binding| ComponentValue::Object(encode_script_binding_for_editing(binding)))
                .collect(),
        ),
    )]))
}
