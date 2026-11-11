//! `Editor/Sources/EditorCore/Scene/Adapter/EditorSceneAdapter.swift`.
//!
//! 主线程约定的编辑器场景适配层。底层数据来自 `SceneRuntime`；面板只读取这里
//! 导出的树与属性 schema。
//!
//! Swift's `final class @unchecked Sendable` is a shared, mutable reference held
//! by many editor subsystems, so the Rust port keeps the same shape with
//! `RefCell` (`Rc`/`RefCell` per MIGRATION.md §5.5) and `&self` methods.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::rendering::render_scene::RenderCamera;
use diffuse_scene::scene_bootstrap::SceneBootstrapDefaultsResource;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_scene::scripting::SharedRuntimeScriptDriver;
use diffuse_script::ScriptRuntime;
use diffuse_script::input::default_input_actions::DefaultInputActions;
use diffuse_script::interop::component_registry_script_codec::ComponentRegistryScriptCodec;

use diffuse_intent::transactions::transaction_executor::TransactionExecutor;

use crate::scene::adapter::particles::feedback::ParticleFeedbackInbox;
use crate::scene::editor_inspector_schema::EditorInspectorSection;
use crate::scene::history::editor_scene_edit_history::EditorSceneEditHistory;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalogEntry;

pub struct EditorSceneAdapter {
    scene: RefCell<SceneRuntime>,
    pub editor_viewport_camera: Cell<RenderCamera>,
    uses_editor_viewport_camera: Cell<bool>,
    pub on_viewport_camera_changed: RefCell<Option<Rc<dyn Fn()>>>,
    pub transaction_executor: TransactionExecutor,
    pub initial_selection_id: Cell<Option<u64>>,
    pub initial_expanded_ids: RefCell<BTreeSet<u64>>,
    pub script_runtime: ScriptRuntime,
    pub script_catalog_entries: RefCell<Vec<ProjectScriptCatalogEntry>>,
    pub managed_script_identifiers: RefCell<BTreeSet<String>>,
    pub dynamic_script_display_names: RefCell<BTreeMap<String, String>>,
    pub dynamic_script_aliases: RefCell<BTreeMap<String, String>>,
    pub particle_feedback: ParticleFeedbackInbox,
    pub inspector_renderers: RefCell<EditorInspectorRendererRegistry>,
    pub edit_history: RefCell<EditorSceneEditHistory>,
    is_authoring_enabled: Cell<bool>,
    pub on_revision_changed: RefCell<Option<Rc<dyn Fn(u64)>>>,
    pub on_transaction_error: RefCell<Option<Rc<dyn Fn(String)>>>,
    pub additional_inspector_sections:
        RefCell<Option<Rc<dyn Fn(u64) -> Vec<EditorInspectorSection>>>>,
}

impl EditorSceneAdapter {
    /// Navigation is session state, independent of authored game cameras.
    pub fn default_viewport_camera() -> RenderCamera {
        RenderCamera::new(Float3::new(6.0, 4.0, 8.0), Float3::ZERO)
    }

    /// Swift's initializer. Its default arguments require the built-in renderer
    /// registry (a later batch), so callers pass the registry explicitly.
    pub fn new(
        seed_preview_scene: bool,
        component_registry: ComponentRegistry,
        inspector_renderers: EditorInspectorRendererRegistry,
    ) -> Self {
        let mut registry = component_registry;
        registry.register_default_script_codec();
        let mut scene = SceneRuntime::new(registry);
        if seed_preview_scene {
            scene.bootstrap_editor_preview_scene();
        }
        scene.set_resource(
            <diffuse_scene::input_action::InputActionMap as DefaultInputActions>::cove_default(),
        );
        let script_runtime = ScriptRuntime::new();
        scene.set_script_driver(SharedRuntimeScriptDriver::new(Box::new(
            script_runtime.clone(),
        )));
        let defaults = scene.resource::<SceneBootstrapDefaultsResource>();
        let initial_selection_id = defaults
            .as_ref()
            .and_then(|defaults| defaults.default_selection)
            .map(|entity| entity.raw_value());
        let initial_expanded_ids: BTreeSet<u64> = defaults
            .as_ref()
            .map(|defaults| {
                defaults
                    .default_expanded
                    .iter()
                    .map(|entity| entity.raw_value())
                    .collect()
            })
            .unwrap_or_default();
        let mut edit_history = EditorSceneEditHistory::with_limit(100);
        edit_history.reset(scene.clone());
        EditorSceneAdapter {
            scene: RefCell::new(scene),
            editor_viewport_camera: Cell::new(Self::default_viewport_camera()),
            uses_editor_viewport_camera: Cell::new(false),
            on_viewport_camera_changed: RefCell::new(None),
            transaction_executor: TransactionExecutor::new(),
            initial_selection_id: Cell::new(initial_selection_id),
            initial_expanded_ids: RefCell::new(initial_expanded_ids),
            script_runtime,
            script_catalog_entries: RefCell::new(Vec::new()),
            managed_script_identifiers: RefCell::new(BTreeSet::new()),
            dynamic_script_display_names: RefCell::new(BTreeMap::new()),
            dynamic_script_aliases: RefCell::new(BTreeMap::new()),
            particle_feedback: ParticleFeedbackInbox::new(),
            inspector_renderers: RefCell::new(inspector_renderers),
            edit_history: RefCell::new(edit_history),
            is_authoring_enabled: Cell::new(true),
            on_revision_changed: RefCell::new(None),
            on_transaction_error: RefCell::new(None),
            additional_inspector_sections: RefCell::new(None),
        }
    }

    /// A snapshot of the authored scene.
    pub fn scene(&self) -> SceneRuntime {
        self.scene.borrow().clone()
    }

    /// Replaces the scene the way Swift's `didSet` did: the script driver is
    /// re-attached to the new value.
    pub fn set_scene(&self, scene: SceneRuntime) {
        self.scene.replace(scene);
        self.attach_script_driver();
    }

    fn attach_script_driver(&self) {
        self.scene
            .borrow_mut()
            .set_script_driver(SharedRuntimeScriptDriver::new(Box::new(
                self.script_runtime.clone(),
            )));
    }

    pub fn set_editor_viewport_camera_enabled(&self, enabled: bool) {
        if self.uses_editor_viewport_camera.get() == enabled {
            return;
        }
        self.uses_editor_viewport_camera.set(enabled);
        if let Some(handler) = self.on_viewport_camera_changed.borrow().clone() {
            handler();
        }
    }

    pub fn uses_editor_viewport_camera(&self) -> bool {
        self.uses_editor_viewport_camera.get()
    }

    pub fn set_authoring_enabled(&self, is_enabled: bool) {
        self.is_authoring_enabled.set(is_enabled);
        if !is_enabled {
            self.end_interactive_edit_history_group();
        }
    }

    pub fn is_authoring_enabled(&self) -> bool {
        self.is_authoring_enabled.get()
    }

    pub fn reset_to_preview_scene(&self) {
        self.reset_to_preview_scene_notify(true);
    }

    pub fn reset_to_preview_scene_notify(&self, notify: bool) {
        let registry = self.scene.borrow().component_registry().clone();
        let mut scene = SceneRuntime::new(registry);
        scene.bootstrap_editor_preview_scene();
        scene.set_resource(
            <diffuse_scene::input_action::InputActionMap as DefaultInputActions>::cove_default(),
        );
        self.script_runtime.reset();
        scene.set_script_driver(SharedRuntimeScriptDriver::new(Box::new(
            self.script_runtime.clone(),
        )));
        self.invalidate_particle_feedback();
        let defaults = scene.resource::<SceneBootstrapDefaultsResource>();
        self.initial_selection_id.set(
            defaults
                .as_ref()
                .and_then(|defaults| defaults.default_selection)
                .map(|entity| entity.raw_value()),
        );
        self.initial_expanded_ids.replace(
            defaults
                .as_ref()
                .map(|defaults| {
                    defaults
                        .default_expanded
                        .iter()
                        .map(|entity| entity.raw_value())
                        .collect()
                })
                .unwrap_or_default(),
        );
        self.set_scene(scene);
        self.reset_edit_history();
        if notify {
            self.notify_revision_changed(false, None);
        }
    }

    pub fn revision(&self) -> u64 {
        self.scene.borrow().snapshot().revision
    }

    pub fn entity_count(&self) -> usize {
        self.scene.borrow().snapshot().entity_count
    }

    /// True while any emitter can still emit or has live particles. The editor
    /// consults this only while realtime preview or playback is active; ordinary
    /// inspector/devtools work should not keep the scene simulation running.
    pub fn has_active_particles(&self) -> bool {
        let scene = self.scene.borrow();
        for entity in scene.entities_with::<ParticleEmitter>() {
            let Some(emitter) = scene.component::<ParticleEmitter>(entity) else {
                continue;
            };
            if emitter.is_emission_active() || emitter.alive_count() > 0 {
                return true;
            }
        }
        false
    }

    pub fn default_selection_id(&self) -> Option<u64> {
        self.initial_selection_id.get()
    }

    pub fn default_expanded_entity_ids(&self) -> BTreeSet<u64> {
        self.initial_expanded_ids.borrow().clone()
    }

    pub fn invalidate_particle_feedback(&self) {
        self.particle_feedback.invalidate();
    }

    pub(crate) fn notify_revision_handlers(&self, revision: u64) {
        if let Some(handler) = self.on_revision_changed.borrow().clone() {
            handler(revision);
        }
    }

    pub(crate) fn notify_transaction_error(&self, message: &str) {
        if let Some(handler) = self.on_transaction_error.borrow().clone() {
            handler(message.to_string());
        }
    }
}

/// Swift's `EntityID` used by inspector renderers.
pub type AdapterEntityID = EntityID;
