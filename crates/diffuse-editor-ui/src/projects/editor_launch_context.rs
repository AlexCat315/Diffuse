//! Project, engine and window lifecycle from EditorLaunchContext.swift.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::sync::Arc;
use std::time::Duration;

use cove_graphics::rhi::Device;
use cove_ui_addons::workspace::{WorkspaceController, WorkspacePanelRegistry};
use cove_logging::{Level, LogEvent, LogSystem};
use cove_platform::WindowId;
use cove_runtime::PlatformEventBridge;
use cove_ui::hosts::AppDisplayHandle;
use cove_ui::hosts::desktop::display::AppAuxiliaryWindowRequest;
use cove_ui_compose::AnyView;
use crate::localization::localized;
use crate::commands::catalog::{EditorCommandCatalog, EditorCommandContext, EditorCommandItem};
use crate::commands::dispatcher::EditorCommandDispatcher;
use crate::shell::menu::native::EditorNativeMenuBuilder;
use crate::root::chrome::settings_window_root::EditorSettingsWindowRoot;
use cove_ui_compose::scene_core::{ObservableObject, ObservablePublisher};
use cove_runtime::scene::{LocalInvalidationHandle, UIWorkSchedulerHolder};
use diffuse_editor_core::application::editor_application::{EditorApplication, EditorApplicationOptions};
use diffuse_editor_core::assets::asset_catalog::EditorViewportDropTarget;
use diffuse_editor_core::editing::viewport::editor_viewport_frame_drive::EditorViewportFrameDrive;
use diffuse_editor_core::editing::viewport::editor_viewport_input_controller::EditorViewportInputController;
use diffuse_editor_core::localization::EditorLocalizationPreferences;
use diffuse_editor_core::projects::editor_project_lifecycle::EditorProjectLifecycle;
use diffuse_editor_core::projects::editor_scratch_workspace::EditorScratchWorkspace;
use diffuse_editor_core::rendering::hud::in_game_ui_host::InGameUIHost;
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::{EditorConsoleSeverity, EditorPendingCloseRequest};
use diffuse_editor_core::state::editor_store::SubscriptionToken;
use diffuse_editor_core::state::workspace::content::EditorContent;
use diffuse_editor_core::state::workspace::editor_workbench_state::EditorViewportMode;

use super::frame_cadence::EditorFrameCadence;
use super::project_list::EditorProjectList;
use crate::root::root_view_factory::{EditorShellState, make_workspace_registry};
use crate::root::workspace::editor_workspace_defaults::EditorWorkspaceDefaults;

type LaunchError = Box<dyn Error>;

thread_local! {
    static CURRENT: RefCell<Weak<EditorLaunchContext>> = const { RefCell::new(Weak::new()) };
}

pub fn has_current() -> bool {
    EditorLaunchContext::current().is_some()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorProjectEntry {
    pub directory: String,
    pub name: String,
}

pub struct EditorLaunchBundle {
    pub app: Rc<EditorApplication>,
    pub controller: Rc<RefCell<WorkspaceController>>,
    pub registry: WorkspacePanelRegistry,
    window_preferences: Cell<Option<SubscriptionToken>>,
}

pub struct EditorLaunchContext {
    pub events: PlatformEventBridge,
    pub in_game_ui: InGameUIHost,
    render_device: Arc<Device>,
    projects: RefCell<Vec<EditorProjectEntry>>,
    active_directory: RefCell<Option<String>>,
    open_failure: RefCell<Option<String>>,
    loaded: RefCell<BTreeMap<String, Rc<EditorLaunchBundle>>>,
    display: RefCell<Option<AppDisplayHandle>>,
    background_display: RefCell<Option<LocalInvalidationHandle>>,
    close_answered: RefCell<BTreeSet<String>>,
    frame_cadence: RefCell<EditorFrameCadence>,
    should_expand: Cell<bool>,
    settings_window: Cell<Option<WindowId>>,
    last_native_menu: RefCell<Option<(String, EditorContent)>>,
    shell_state: RefCell<Option<EditorShellState>>,
    state_directory: PathBuf,
    watch_plugins: bool,
    review_plugin: RefCell<Option<String>>,
    publisher: ObservablePublisher,
}

impl EditorLaunchContext {
    pub fn new(
        render_device: Arc<Device>,
        in_game_ui: InGameUIHost,
        state_directory: PathBuf,
        settings_requested: bool,
        watch_plugins: bool,
        review_plugin: Option<String>,
    ) -> Rc<Self> {
        let shell_state = EditorShellState::load(&state_directory);
        if let Some(state) = &shell_state {
            EditorLocalizationPreferences::set_language(state.language);
        }
        let context = Rc::new(Self {
            events: PlatformEventBridge::default(),
            in_game_ui,
            render_device,
            projects: RefCell::default(),
            active_directory: RefCell::default(),
            open_failure: RefCell::default(),
            loaded: RefCell::default(),
            display: RefCell::default(),
            background_display: RefCell::default(),
            close_answered: RefCell::default(),
            frame_cadence: RefCell::default(),
            should_expand: Cell::new(!settings_requested),
            settings_window: Cell::new(None),
            last_native_menu: RefCell::default(),
            shell_state: RefCell::new(shell_state),
            state_directory,
            watch_plugins,
            review_plugin: RefCell::new(review_plugin),
            publisher: ObservablePublisher::default(),
        });
        CURRENT.with(|current| current.replace(Rc::downgrade(&context)));
        context
    }

    pub fn current() -> Option<Rc<Self>> {
        CURRENT.with(|current| current.borrow().upgrade())
    }

    pub fn projects(&self) -> Vec<EditorProjectEntry> {
        self.projects.borrow().clone()
    }

    pub fn active_directory(&self) -> Option<String> {
        self.active_directory.borrow().clone()
    }

    pub fn open_failure(&self) -> Option<String> {
        self.open_failure.borrow().clone()
    }

    pub fn shell_state(&self) -> Option<EditorShellState> {
        self.shell_state.borrow().clone()
    }

    pub fn bundle(&self) -> Option<Rc<EditorLaunchBundle>> {
        self.active_directory().and_then(|path| self.bundle_for(&path))
    }

    pub fn bundle_for(&self, directory: &str) -> Option<Rc<EditorLaunchBundle>> {
        self.loaded.borrow().get(directory).cloned()
    }

    fn loaded_bundles(&self) -> Vec<Rc<EditorLaunchBundle>> {
        let mut loaded = self.loaded.borrow().clone();
        let mut ordered = self.projects.borrow().iter()
            .filter_map(|entry| loaded.remove(&entry.directory)).collect::<Vec<_>>();
        ordered.extend(loaded.into_values());
        ordered
    }

    pub fn restore_projects(self: &Rc<Self>, front: Option<&str>) {
        let saved = EditorProjectList::load();
        let projects = saved.paths.into_iter()
            .filter(|path| !EditorScratchWorkspace::is_scratch(Path::new(path)))
            .filter_map(|path| EditorProjectLifecycle::inspect(Path::new(&path), false).ok())
            .map(|location| EditorProjectEntry {
                name: location.name(),
                directory: location.directory.to_string_lossy().into_owned(),
            })
            .collect();
        self.projects.replace(projects);
        if let Some(front) = front {
            match self.open_project(front) {
                Ok(()) => return,
                Err(error) => self.report_open_error(front, &*error),
            }
        }
        let mut candidates = self.projects();
        if let Some(preferred) = saved.active
            && let Some(index) = candidates.iter().position(|entry| entry.directory == preferred)
        {
            candidates.rotate_left(index);
        }
        for entry in candidates {
            match self.activate(&entry.directory) {
                Ok(()) => break,
                Err(error) => {
                    self.report_open_error(&entry.directory, &*error);
                    self.projects.borrow_mut().retain(|project| project.directory != entry.directory);
                }
            }
        }
        if self.active_directory().is_none() {
            self.open_scratch_workspace();
        }
        self.persist();
        self.publish();
    }

    pub fn open_project(self: &Rc<Self>, directory: &str) -> Result<(), LaunchError> {
        let location = EditorProjectLifecycle::adopt(Path::new(directory))?;
        let path = location.directory.to_string_lossy().into_owned();
        if !self.projects.borrow().iter().any(|entry| entry.directory == path)
            && !EditorScratchWorkspace::is_scratch(&location.directory)
        {
            self.projects.borrow_mut().push(EditorProjectEntry {
                directory: path.clone(),
                name: location.name(),
            });
        }
        if let Err(error) = self.activate(&path) {
            if self.bundle_for(&path).is_none() {
                self.projects.borrow_mut().retain(|entry| entry.directory != path);
            }
            self.persist();
            self.publish();
            return Err(error);
        }
        Ok(())
    }

    pub fn request_open_folder(self: &Rc<Self>) {
        let display = self.display.borrow().clone();
        let Some(display) = display else { return };
        let current = self.active_directory();
        let context = Rc::downgrade(self);
        display.request_open_folder(current.as_deref(), Box::new(move |path| {
            if let (Some(context), Some(path)) = (context.upgrade(), path)
                && let Err(error) = context.open_project(&path)
            {
                context.report_open_error(&path, &*error);
                context.publish();
            }
        }));
    }

    pub fn open_scratch_workspace(self: &Rc<Self>) -> bool {
        let result = (|| {
            let path = EditorScratchWorkspace::prepare()?;
            self.activate(&path.to_string_lossy())
        })();
        if let Err(error) = result {
            self.report_open_error("Untitled Workspace", &*error);
            self.publish();
            return false;
        }
        true
    }

    pub fn activate(self: &Rc<Self>, directory: &str) -> Result<(), LaunchError> {
        let next = match self.bundle_for(directory) {
            Some(bundle) => bundle,
            None => {
                let bundle = self.make_bundle(directory)?;
                self.loaded.borrow_mut().insert(directory.to_owned(), bundle.clone());
                bundle
            }
        };
        let previous = self.bundle();
        if previous.as_ref().is_some_and(|bundle| Rc::ptr_eq(bundle, &next)) {
            return Ok(());
        }
        if let Some(previous) = previous {
            previous.app.stop_mcp_bridge();
            previous.app.enqueue_viewport_input(cove_platform::InputEvent::WindowFocusLost);
        }
        if let Some(window) = self.settings_window.take()
            && let Some(display) = self.display.borrow().as_ref()
        {
            display.close_window(window);
        }
        EditorViewportInputController::shared().reset();
        EditorViewportDropTarget::set_frame(None);
        self.active_directory.replace(Some(directory.to_owned()));
        self.open_failure.replace(None);
        let state = self.shell_state.borrow().clone();
        if let Some(state) = state {
            state.apply(&next.app);
        }
        if let Err(error) = next.app.start_mcp_bridge() {
            next.app.log_console("MCP bridge failed to start", EditorConsoleSeverity::Warning,
                Some(error.to_string()), None, None);
        }
        if let Some(path) = self.review_plugin.borrow_mut().take() {
            next.app.inspect_plugin_for_management(Path::new(&path));
        }
        if let Some(display) = self.display.borrow().as_ref() {
            display.set_vsync_enabled(next.app.store.vsync_mode().is_enabled());
        }
        self.refresh_native_menu();
        self.persist();
        self.publish();
        Ok(())
    }

    pub fn close_project(self: &Rc<Self>, directory: &str) {
        let front = self.active_directory().as_deref() == Some(directory);
        let Some(index) = self.projects.borrow().iter().position(|entry| entry.directory == directory) else {
            return;
        };
        let bundle = self.loaded.borrow_mut().remove(directory);
        if let Some(bundle) = bundle {
            if front {
                self.save_shell_state(&bundle.app);
            }
            self.teardown(&bundle);
        }
        self.projects.borrow_mut().remove(index);
        if front {
            self.active_directory.take();
            EditorViewportDropTarget::set_frame(None);
            let mut candidates = self.projects();
            let index = index.min(candidates.len());
            candidates.rotate_left(index);
            for entry in candidates {
                if self.activate(&entry.directory).is_ok() {
                    break;
                }
            }
            if self.active_directory().is_none() {
                self.open_scratch_workspace();
            }
        }
        self.persist();
        self.publish();
    }

    fn make_bundle(self: &Rc<Self>, directory: &str) -> Result<Rc<EditorLaunchBundle>, LaunchError> {
        let preferences = self.shell_state.borrow().clone();
        let app = EditorApplication::with_options(directory.to_owned(), EditorApplicationOptions {
            render_device: Some(self.render_device.clone()),
            in_game_ui: Some(self.in_game_ui.render_provider()),
            events: self.events.clone(),
            initial_ai_settings: preferences.as_ref().map(|state| state.ai_settings.clone()).unwrap_or_default(),
            initial_capability_settings: preferences.as_ref().map(|state| state.capability_settings.clone()).unwrap_or_default(),
            ..EditorApplicationOptions::default()
        })?;
        if let Some(preferences) = preferences {
            preferences.apply(&app);
        }
        let weak = Rc::downgrade(self);
        let path = directory.to_owned();
        app.set_close_project_handler(Some(Rc::new(move || {
            if let Some(context) = weak.upgrade() {
                context.close_project(&path);
            }
        })));
        let had_scene = app.restore_project_scene_at_launch().is_some();
        app.store.dispatch(EditorAction::SetContent(if had_scene { EditorContent::Scene } else { EditorContent::Files }));
        if let Err(error) = app.bootstrap() {
            app.shutdown();
            return Err(error.into());
        }
        app.enable_bundled_plugins();
        app.workstation.version_control.start_monitoring();
        app.workstation.tasks.refresh();
        if self.watch_plugins {
            app.start_watching_plugin_packages(Duration::from_secs(1));
        }
        self.wire_app_display(&app);
        let registry = make_workspace_registry(&app);
        let document = EditorWorkspaceDefaults::make_document(&registry, app.store.content());
        let controller = Rc::new(RefCell::new(WorkspaceController::new(document)));
        let bundle = Rc::new(EditorLaunchBundle { app, controller, registry, window_preferences: Cell::new(None) });
        let previous = RefCell::new(EditorShellState::from_store(&bundle.app.store));
        let previous_content = Cell::new(bundle.app.store.content());
        let context = Rc::downgrade(self);
        let app = Rc::downgrade(&bundle.app);
        let token = bundle.app.store.subscribe(Rc::new(move |store| {
            let content = store.content();
            if content != previous_content.replace(content)
                && let Some(context) = context.upgrade()
            {
                context.refresh_native_menu();
            }
            let next = EditorShellState::from_store(store);
            if next == *previous.borrow() {
                return;
            }
            previous.replace(next);
            if let (Some(context), Some(app)) = (context.upgrade(), app.upgrade())
                && context.active_directory().as_deref() == Some(app.project_directory.as_str())
            {
                context.save_shell_state(&app);
                context.last_native_menu.take();
                context.refresh_native_menu();
                if let Some(display) = context.display.borrow().as_ref() {
                    display.set_vsync_enabled(store.vsync_mode().is_enabled());
                }
                context.publish();
            }
        }));
        bundle.window_preferences.set(Some(token));
        Ok(bundle)
    }

    pub fn wire_display(self: &Rc<Self>, display: &AppDisplayHandle) {
        self.display.replace(Some(display.clone()));
        let wake_display = display.clone();
        self.background_display.replace(Some(LocalInvalidationHandle::new(move |_| {
            request_window_display(&wake_display);
        })));
        self.expand_window();
        for bundle in self.loaded_bundles() {
            self.wire_app_display(&bundle.app);
        }
        let weak = Rc::downgrade(self);
        display.set_window_close_interceptor(Some(Rc::new(move |window| {
            let Some(context) = weak.upgrade() else { return true };
            let main = context.display.borrow().as_ref().and_then(AppDisplayHandle::main_window_id);
            if window.is_some() && window != main {
                return true;
            }
            context.close_answered.borrow_mut().clear();
            !context.ask_before_close(window)
        })));
        if let Some(bundle) = self.bundle() {
            display.set_vsync_enabled(bundle.app.store.vsync_mode().is_enabled());
        }
        self.last_native_menu.take();
        self.refresh_native_menu();
        request_window_display(display);
    }

    fn refresh_native_menu(self: &Rc<Self>) {
        if !cove_ui::NativeMenuBar::is_supported() {
            return;
        }
        let display = self.display.borrow().clone();
        let Some(display) = display else { return };
        let Some(bundle) = self.bundle() else {
            let context = Rc::downgrade(self);
            let bar = EditorNativeMenuBuilder::projectless("Diffuse", move || {
                if let Some(context) = context.upgrade() {
                    context.request_open_folder();
                }
            });
            display.install_native_menu_bar(&bar);
            return;
        };
        let context = EditorCommandContext::from_application(&bundle.app);
        let key = (bundle.app.project_directory.clone(), context.content);
        if self.last_native_menu.borrow().as_ref() == Some(&key) {
            return;
        }
        self.last_native_menu.replace(Some(key));
        let mut catalog = EditorCommandCatalog::make(&context);
        retain_wired_commands(&mut catalog.application_items);
        for menu in &mut catalog.menus {
            retain_wired_commands(&mut menu.items);
        }
        let weak_context = Rc::downgrade(self);
        let weak_bundle = Rc::downgrade(&bundle);
        let availability = Rc::downgrade(&bundle);
        let bar = EditorNativeMenuBuilder::make_with_availability("Diffuse", &catalog, Rc::new(move |command| {
            if let (Some(context), Some(bundle)) = (weak_context.upgrade(), weak_bundle.upgrade()) {
                EditorCommandDispatcher::handle(command, &bundle, &context);
            }
        }), Rc::new(move |entry| {
            availability.upgrade().is_some_and(|bundle| {
                let catalog = EditorCommandCatalog::make(&EditorCommandContext::from_application(&bundle.app));
                catalog.entries().into_iter().find(|current| current.id == entry.id).is_some_and(|current| {
                    EditorCommandDispatcher::is_enabled(&current.command, current.is_enabled)
                })
            })
        }));
        display.install_native_menu_bar(&bar);
    }

    pub fn open_settings_window(&self, app: &Rc<EditorApplication>) {
        let display = self.display.borrow().clone();
        let Some(display) = display else { return };
        if self.settings_window.get().is_some_and(|window| display.is_window_open(window)) {
            return;
        }
        let request = AppAuxiliaryWindowRequest {
            title: localized("Settings"),
            width: 1040,
            height: 780,
            root_view: AnyView::new(EditorSettingsWindowRoot(app.clone())),
            rendering: Default::default(),
        };
        self.settings_window.set(display.open_window(request));
    }

    fn wire_app_display(&self, app: &EditorApplication) {
        app.set_background_display_waker(self.background_display.borrow().as_ref().map(|handle| handle.invalidator()));
        let display = self.display.borrow().clone();
        app.set_display_invalidation_handler(display.map(|display| {
            Rc::new(move || request_window_display(&display)) as Rc<dyn Fn()>
        }));
    }

    fn ask_before_close(self: &Rc<Self>, window: Option<WindowId>) -> bool {
        let front = self.bundle();
        let candidates = front.iter().cloned().chain(self.loaded_bundles().into_iter()
            .filter(|bundle| front.as_ref().is_none_or(|front| !Rc::ptr_eq(front, bundle))));
        let next = candidates.into_iter().find(|bundle| {
            !self.close_answered.borrow().contains(&bundle.app.project_directory)
                && (bundle.app.has_unsaved_scene_changes() || bundle.app.workstation.has_unsaved_changes())
        });
        let Some(next) = next else { return false };
        if self.activate(&next.app.project_directory).is_err() {
            return true;
        }
        next.app.store.dispatch(EditorAction::RequestClose(EditorPendingCloseRequest::with_options(
            diffuse_editor_core::state::editor_state::EditorPendingDocumentAction::Close,
            window.map(|id| id.0), None,
        )));
        self.publish();
        true
    }

    pub fn continue_close(self: &Rc<Self>, window: Option<WindowId>, app: &EditorApplication) {
        self.close_answered.borrow_mut().insert(app.project_directory.clone());
        if !self.ask_before_close(window)
            && let Some(display) = self.display.borrow().as_ref()
        {
            match window {
                Some(id) => display.close_window(id),
                None => display.quit(),
            }
        }
    }

    pub fn tick(self: &Rc<Self>, elapsed: f64) {
        self.expand_window();
        let Some(bundle) = self.bundle() else { return };
        let app = &bundle.app;
        let store = &app.store;
        let interacting = EditorViewportInputController::shared().is_continuous_scene_interaction_active();
        let continuous = EditorViewportFrameDrive::wants_continuous_frames(
            store.viewport_realtime_enabled(), store.playback_state(), interacting, store.should_render(),
        );
        if let Some(display) = self.display.borrow().as_ref()
            && let Some(mode) = self.frame_cadence.borrow_mut().update(continuous, store.vsync_mode().is_enabled())
        {
            display.set_frame_rate_mode(mode);
        }
        app.tick(elapsed);
        if store.should_render() {
            let game = store.viewport_mode() == EditorViewportMode::Game;
            let fixed = game.then(|| store.game_preview_resolution().size()).flatten();
            let frame = EditorViewportDropTarget::frame();
            let (width, height) = match fixed {
                Some(size) => (size.width, size.height),
                None => frame.map(|frame| (frame.width.round() as u32, frame.height.round() as u32)).unwrap_or((1280, 720)),
            };
            let scale = if fixed.is_some() { 1.0 } else { cove_ui::core::content_scale().max(1.0) };
            let canvas = if game && store.game_preview_hud_enabled() { app.scene.current_in_game_canvas() } else { Default::default() };
            self.in_game_ui.tick(width, height, scale, canvas);
        }
    }

    fn expand_window(&self) {
        if self.should_expand.get()
            && let Some(display) = self.display.borrow().as_ref()
            && display.main_window_id().is_some()
        {
            self.should_expand.set(false);
            display.maximize_window();
        }
    }

    pub fn shutdown(&self) {
        if let Some(bundle) = self.bundle() {
            self.save_shell_state(&bundle.app);
        }
        for bundle in self.loaded.take().into_values() {
            self.teardown(&bundle);
        }
        self.active_directory.take();
        self.display.take();
        self.background_display.take();
        EditorViewportDropTarget::set_frame(None);
        CURRENT.with(|current| {
            if std::ptr::eq(current.borrow().as_ptr(), self) {
                current.replace(Weak::new());
            }
        });
    }

    fn teardown(&self, bundle: &EditorLaunchBundle) {
        if let Some(token) = bundle.window_preferences.take() {
            bundle.app.store.unsubscribe(token);
        }
        bundle.app.set_close_project_handler(None);
        bundle.app.set_display_invalidation_handler(None);
        bundle.app.set_background_display_waker(None);
        bundle.app.shutdown();
    }

    fn save_shell_state(&self, app: &EditorApplication) {
        let state = EditorShellState::from_store(&app.store);
        EditorLocalizationPreferences::set_language(state.language);
        state.save(&self.state_directory);
        self.shell_state.replace(Some(state));
    }

    fn persist(&self) {
        let paths = self.projects.borrow().iter()
            .map(|entry| entry.directory.clone()).collect::<Vec<_>>();
        let active = self.active_directory().filter(|path| paths.contains(path));
        EditorProjectList { paths, active }.save();
    }

    fn report_open_error(&self, directory: &str, error: &dyn Error) {
        LogSystem::logger("com.cove.editor").log(&LogEvent::new(
            Level::Warning, format!("Could not open {directory}: {error}"),
        ));
        if let Some(bundle) = self.bundle() {
            bundle.app.log_console("Could not open project", EditorConsoleSeverity::Error,
                Some(error.to_string()), None, None);
        } else {
            self.open_failure.replace(Some(error.to_string()));
        }
    }

    fn publish(&self) {
        self.publisher.send();
        if let Some(display) = self.display.borrow().as_ref() {
            request_window_display(display);
        }
    }
}

fn retain_wired_commands(items: &mut Vec<EditorCommandItem>) {
    items.retain_mut(|item| match item {
        EditorCommandItem::Entry(entry) => EditorCommandDispatcher::is_wired(&entry.command),
        EditorCommandItem::Submenu(menu) => {
            retain_wired_commands(&mut menu.items);
            !menu.items.is_empty()
        }
        EditorCommandItem::Separator => true,
    });
}

fn request_window_display(display: &AppDisplayHandle) {
    let display = display.clone();
    UIWorkSchedulerHolder::schedule(Rc::new(move || display.request_display()));
}

impl ObservableObject for EditorLaunchContext {
    fn register_observer(&self, handler: Rc<dyn Fn()>) -> u64 {
        self.publisher.register_observer(handler)
    }

    fn unregister_observer(&self, token: u64) {
        self.publisher.unregister_observer(token);
    }
}
