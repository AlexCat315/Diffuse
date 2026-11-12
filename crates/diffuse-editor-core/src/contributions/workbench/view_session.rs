//! Translation of
//! `Editor/Sources/EditorCore/Contributions/Workbench/ViewSession.swift`.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use diffuse_plugin::PluginError;
use diffuse_plugin::contract::plugin_json::PluginJSON;
use diffuse_plugin::contribution::workbench::tree::{UINode, UINodeKind};
use diffuse_plugin::contribution::workbench::view::{PluginViewResult, UIEffect, UIEvent};

use crate::application::plugins::ui_queue::PluginUIQueue;
use crate::contributions::workbench::contributed::{ContributedPanel, WorkbenchCatalog};
use crate::contributions::workbench::placements::ContributedDocumentView;

/// What a [`PluginViewSession`] shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PluginContentSource {
    Panel(ContributedPanel),
    Document(ContributedDocumentView, String),
}

impl PluginContentSource {
    pub fn plugin_id(&self) -> &str {
        match self {
            PluginContentSource::Panel(panel) => &panel.plugin_id,
            PluginContentSource::Document(view, _) => &view.plugin_id,
        }
    }

    pub fn key(&self) -> String {
        match self {
            PluginContentSource::Panel(panel) => format!("panel:{}", panel.id),
            PluginContentSource::Document(view, path) => {
                format!("document:{}.{}:{}", view.plugin_id, view.id, path)
            }
        }
    }

    /// Whether the catalog still contributes exactly this source.
    pub fn is_current(&self, catalog: &WorkbenchCatalog) -> bool {
        match self {
            PluginContentSource::Panel(panel) => catalog.panel(&panel.id) == Some(panel),
            PluginContentSource::Document(view, _) => catalog.document_views.contains(view),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PluginViewSnapshot {
    pub ui: Option<UINode>,
    pub is_busy: bool,
    pub failure: Option<String>,
}

/// The value both the session and the host read for one view. `invoke` runs on
/// the calling thread (Swift awaited a main-actor task); the UI queue only
/// carries debounced events and refreshes.
pub struct PluginViewSession {
    source: PluginContentSource,
    invoke: Arc<
        dyn Fn(Option<&PluginJSON>, Option<&UIEvent>) -> Result<PluginViewResult, PluginError>
            + Send
            + Sync,
    >,
    ui_queue: Arc<PluginUIQueue>,
    state: Mutex<SessionState>,
    effect_handler: Mutex<Option<Arc<dyn Fn(Vec<UIEffect>) + Send + Sync>>>,
    observers: Mutex<BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>>,
    next_observer: AtomicU64,
    invoke_lock: Mutex<()>,
}

struct SessionState {
    snapshot: PluginViewSnapshot,
    values: BTreeMap<String, PluginJSON>,
    plugin_values: BTreeMap<String, PluginJSON>,
    state_json: Option<PluginJSON>,
    pending: usize,
    is_cancelled: bool,
    refresh_generation: u64,
    change_generation: u64,
}

impl PluginViewSession {
    /// Swift's `changeDelay`: typing pauses this long before the change action.
    pub const CHANGE_DELAY: Duration = Duration::from_millis(300);

    pub fn new(
        source: PluginContentSource,
        invoke: Arc<
            dyn Fn(Option<&PluginJSON>, Option<&UIEvent>) -> Result<PluginViewResult, PluginError>
                + Send
                + Sync,
        >,
        ui_queue: Arc<PluginUIQueue>,
    ) -> Self {
        PluginViewSession {
            source,
            invoke,
            ui_queue,
            state: Mutex::new(SessionState {
                snapshot: PluginViewSnapshot::default(),
                values: BTreeMap::new(),
                plugin_values: BTreeMap::new(),
                state_json: None,
                pending: 0,
                is_cancelled: false,
                refresh_generation: 0,
                change_generation: 0,
            }),
            effect_handler: Mutex::new(None),
            observers: Mutex::new(BTreeMap::new()),
            next_observer: AtomicU64::new(0),
            invoke_lock: Mutex::new(()),
        }
    }

    pub fn source(&self) -> &PluginContentSource {
        &self.source
    }

    pub fn snapshot(&self) -> PluginViewSnapshot {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .snapshot
            .clone()
    }

    pub fn values(&self) -> BTreeMap<String, PluginJSON> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values
            .clone()
    }

    pub fn set_effect_handler(&self, handler: Option<Arc<dyn Fn(Vec<UIEffect>) + Send + Sync>>) {
        *self
            .effect_handler
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    /// Draws the view again from the current state.
    pub fn render(self: &Arc<Self>) {
        self.enqueue(None);
    }

    /// Raises a component's action with the current control values.
    pub fn send(
        self: &Arc<Self>,
        action: &str,
        arguments: Option<PluginJSON>,
        value: Option<PluginJSON>,
    ) {
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.change_generation = state.change_generation.wrapping_add(1);
        }
        let values = self.values();
        self.enqueue(Some(UIEvent {
            action: action.to_string(),
            arguments,
            value,
            values,
        }));
    }

    /// Records a control's new value. With a `change` action, the plugin hears
    /// about it once typing pauses.
    pub fn set_value(self: &Arc<Self>, value: PluginJSON, id: &str, change_action: Option<&str>) {
        let change_generation;
        let values;
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.values.get(id) == Some(&value) {
                return;
            }
            state.values.insert(id.to_string(), value.clone());
            state.change_generation = state.change_generation.wrapping_add(1);
            change_generation = state.change_generation;
            values = state.values.clone();
        }
        self.send_notification();
        let Some(action) = change_action else {
            return;
        };
        let event = UIEvent {
            action: action.to_string(),
            arguments: None,
            value: Some(value),
            values,
        };
        let session = self.clone();
        let ui_queue = self.ui_queue.clone();
        std::thread::spawn(move || {
            std::thread::sleep(PluginViewSession::CHANGE_DELAY);
            let current = session
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .change_generation;
            if current != change_generation {
                return;
            }
            let work = Arc::new(move || session.enqueue(Some(event.clone())));
            ui_queue.schedule(work);
        });
    }

    pub fn cancel(&self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.is_cancelled = true;
        state.refresh_generation = state.refresh_generation.wrapping_add(1);
        state.change_generation = state.change_generation.wrapping_add(1);
    }

    fn enqueue(self: &Arc<Self>, event: Option<UIEvent>) {
        let _invoke = self
            .invoke_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (state_json, values, refresh_generation, cancelled) = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.is_cancelled {
                return;
            }
            state.refresh_generation = state.refresh_generation.wrapping_add(1);
            let refresh_generation = state.refresh_generation;
            state.pending += 1;
            (
                state.state_json.clone(),
                state.values.clone(),
                refresh_generation,
                state.is_cancelled,
            )
        };
        if cancelled {
            return;
        }
        self.publish_snapshot_mutation(|snapshot| snapshot.is_busy = true);

        let event_with_values = event.map(|mut event| {
            event.values = values.clone();
            event
        });
        let result = Some((self.invoke)(
            state_json.as_ref(),
            event_with_values.as_ref(),
        ));
        let still_current = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.pending = state.pending.saturating_sub(1);
            let busy = state.pending > 0;
            state.snapshot.is_busy = busy;
            !state.is_cancelled && state.refresh_generation == refresh_generation
        };
        if !still_current {
            self.publish(|_| {});
            return;
        }
        match result {
            Some(Ok(result)) => {
                let after_event = event_with_values.is_some();
                {
                    let mut state = self
                        .state
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if let Some(next) = result.state.clone() {
                        state.state_json = Some(next);
                    }
                    let SessionState {
                        values,
                        plugin_values,
                        ..
                    } = &mut *state;
                    Self::adopt_values(&result.ui, after_event, values, plugin_values);
                    state.snapshot.ui = Some(result.ui.clone());
                    state.snapshot.failure = None;
                    if state.pending == 0 {
                        state.snapshot.is_busy = false;
                    }
                }
                self.publish(|_| {});
                let effects = self
                    .effect_handler
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone();
                if let Some(handler) = effects {
                    handler(result.effects);
                }
                if let Some(milliseconds) = result.refresh_after_milliseconds {
                    let session = self.clone();
                    let ui_queue = self.ui_queue.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(milliseconds.max(0) as u64));
                        let current = session
                            .state
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .refresh_generation;
                        if current != refresh_generation {
                            return;
                        }
                        let work = Arc::new(move || session.render());
                        ui_queue.schedule(work);
                    });
                }
            }
            Some(Err(error)) => {
                {
                    let mut state = self
                        .state
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    state.snapshot.failure = Some(error.to_string());
                    if state.pending == 0 {
                        state.snapshot.is_busy = false;
                    }
                }
                self.publish(|_| {});
            }
            None => {}
        }
    }

    /// Carries out a result's effects; installed by the workbench.
    fn adopt_values(
        tree: &UINode,
        after_event: bool,
        values: &mut BTreeMap<String, PluginJSON>,
        plugin_values: &mut BTreeMap<String, PluginJSON>,
    ) {
        let mut seen: BTreeMap<String, Option<PluginJSON>> = BTreeMap::new();
        collect_values(tree, &mut seen);
        let mut next: BTreeMap<String, PluginJSON> = BTreeMap::new();
        for (id, value) in &seen {
            match value {
                Some(value)
                    if after_event
                        || plugin_values.get(id) != Some(value)
                        || values.get(id).is_none() =>
                {
                    next.insert(id.clone(), value.clone());
                }
                Some(value) => {
                    next.insert(
                        id.clone(),
                        values.get(id).cloned().unwrap_or_else(|| value.clone()),
                    );
                }
                None => {
                    next.insert(
                        id.clone(),
                        values
                            .get(id)
                            .cloned()
                            .unwrap_or_else(|| PluginJSON::String(String::new())),
                    );
                }
            }
        }
        *plugin_values = seen
            .into_iter()
            .filter_map(|(id, value)| value.map(|value| (id, value)))
            .collect();
        *values = next;
    }

    fn publish(&self, change: impl FnOnce(&mut PluginViewSnapshot)) {
        self.publish_snapshot_mutation(change);
    }

    fn publish_snapshot_mutation(&self, change: impl FnOnce(&mut PluginViewSnapshot)) {
        let changed = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut next = state.snapshot.clone();
            change(&mut next);
            if next == state.snapshot {
                false
            } else {
                state.snapshot = next;
                true
            }
        };
        if changed {
            let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
                .observers
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .values()
                .cloned()
                .collect();
            for handler in handlers {
                handler();
            }
        }
    }

    /// Swift's `publisher.send()`: value edits are not part of the snapshot but
    /// still notify observers.
    fn send_notification(&self) {
        let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
            .observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for handler in handlers {
            handler();
        }
    }

    pub fn register_observer(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        let token = self.next_observer.fetch_add(1, Ordering::SeqCst);
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(token, handler);
        token
    }

    pub fn unregister_observer(&self, token: u64) {
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&token);
    }
}

/// The value each control in the tree carries, by component ID; `None` for a
/// field that leaves its text to the host.
fn collect_values(node: &UINode, values: &mut BTreeMap<String, Option<PluginJSON>>) {
    match &node.kind {
        UINodeKind::TextField(field) => {
            values.insert(
                field.id.clone(),
                field.value.clone().map(PluginJSON::String),
            );
        }
        UINodeKind::Toggle(toggle) => {
            values.insert(toggle.id.clone(), Some(PluginJSON::Bool(toggle.value)));
        }
        UINodeKind::Select(select) => {
            values.insert(
                select.id.clone(),
                Some(PluginJSON::String(select.value.clone())),
            );
        }
        UINodeKind::Column(stack) | UINodeKind::Row(stack) => {
            for child in &stack.children {
                collect_values(child, values);
            }
        }
        UINodeKind::Scroll(child) => collect_values(child, values),
        UINodeKind::Section { children, .. } => {
            for child in children {
                collect_values(child, values);
            }
        }
        UINodeKind::Disclosure(disclosure) => {
            for child in &disclosure.children {
                collect_values(child, values);
            }
        }
        UINodeKind::Spacer
        | UINodeKind::Text(_)
        | UINodeKind::Badge { .. }
        | UINodeKind::Icon { .. }
        | UINodeKind::Progress(_)
        | UINodeKind::Button(_)
        | UINodeKind::Table(_) => {}
    }
}
