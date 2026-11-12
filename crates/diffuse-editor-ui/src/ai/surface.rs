//! `Editor/Sources/EditorUI/ai/Surface.swift`.
//!
//! Top-level view identity and the agent side of one window: which view is in
//! front and the shared draft.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};

use cove_ui_compose::primitives::text::TextBuffer;
use cove_ui_compose::scene_core::{ObservableObject, ObservablePublisher};
use diffuse_editor_core::contributions::workbench::contributed::WorkbenchView;
use diffuse_editor_core::state::workspace::content::EditorContent;

use crate::ai::assistant_hosting::AssistantHosting;

/// A top-level view a window can be in.
///
/// The workbench is the editor's own. Every other view exists because an
/// enabled package declared a panel for it — the identity is the name the
/// package used, so no plugin needs its own `isXxxEnabled` flag.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EditorStudioView {
    pub id: String,
}

impl EditorStudioView {
    pub fn new(id: impl Into<String>) -> Self {
        EditorStudioView { id: id.into() }
    }

    pub fn make() -> Self {
        EditorStudioView::new("make")
    }

    /// The agent conversation, named exactly as a package names it.
    pub fn agent() -> Self {
        EditorStudioView::new(WorkbenchView::agent().raw_value)
    }
}

/// What the agent view shows beside the thread.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EditorAssistantCanvas {
    /// Whatever the agent is working on, nothing until it starts.
    #[default]
    Follow,
    Hidden,
    Content(EditorContent),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EditorAssistantRegions {
    pub leading: bool,
    pub trailing: bool,
    pub selected_panels: BTreeMap<String, String>,
}

impl EditorAssistantRegions {
    pub fn new() -> Self {
        EditorAssistantRegions {
            leading: true,
            trailing: false,
            selected_panels: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorAssistantSurfaceState {
    pub regions: BTreeMap<EditorStudioView, EditorAssistantRegions>,
    /// A window opens on the agent view, as Codex does; the workbench is one
    /// switch away.
    pub requested_view: EditorStudioView,
    pub canvas: EditorAssistantCanvas,
    /// Bumped to put the caret in the composer.
    pub focus_request: u64,
    /// False while the window's packages are still registering. The editor is
    /// held back until then, so the first frame is the view the window is
    /// actually going to stay on instead of the workbench it falls back to
    /// while no package has contributed anything yet.
    pub is_ready: bool,
}

impl Default for EditorAssistantSurfaceState {
    fn default() -> Self {
        EditorAssistantSurfaceState {
            regions: BTreeMap::new(),
            requested_view: EditorStudioView::agent(),
            canvas: EditorAssistantCanvas::Follow,
            focus_request: 0,
            is_ready: true,
        }
    }
}

thread_local! {
    static SURFACES: RefCell<BTreeMap<usize, Weak<EditorAssistantSurface>>> =
        RefCell::new(BTreeMap::new());
}

pub struct EditorAssistantSurface {
    state: RefCell<EditorAssistantSurfaceState>,
    draft: RefCell<TextBuffer>,
    /// The views the window can show right now, read through the host. A view a
    /// package stopped contributing is gone; nothing here knows which plugin
    /// that was.
    available_views: Rc<dyn Fn() -> Vec<EditorStudioView>>,
    host: Weak<dyn AssistantHosting>,
    publisher: ObservablePublisher,
}

impl EditorAssistantSurface {
    fn new(host: &Rc<dyn AssistantHosting>) -> Self {
        let weak = Rc::downgrade(host);
        let views = weak.clone();
        EditorAssistantSurface {
            state: RefCell::new(EditorAssistantSurfaceState::default()),
            draft: RefCell::new(TextBuffer::default()),
            available_views: Rc::new(move || {
                views
                    .upgrade()
                    .map(|host| host.studio_views())
                    .unwrap_or_else(|| vec![EditorStudioView::make()])
            }),
            host: weak,
            publisher: ObservablePublisher::default(),
        }
    }

    /// One surface per conversation host: a project's editor, or a standalone
    /// session that belongs to no project.
    pub fn of(host: &Rc<dyn AssistantHosting>) -> Rc<EditorAssistantSurface> {
        let key = Rc::as_ptr(host) as *const () as usize;
        SURFACES.with(|surfaces| {
            if let Some(existing) = surfaces.borrow().get(&key).and_then(Weak::upgrade) {
                return existing;
            }
            let created = Rc::new(EditorAssistantSurface::new(host));
            surfaces.borrow_mut().insert(key, Rc::downgrade(&created));
            created
        })
    }

    /// A closed host's address can be reused by the next one.
    pub fn release(host: &Rc<dyn AssistantHosting>) {
        let key = Rc::as_ptr(host) as *const () as usize;
        SURFACES.with(|surfaces| {
            surfaces.borrow_mut().remove(&key);
        });
    }

    pub fn state(&self) -> EditorAssistantSurfaceState {
        self.state.borrow().clone()
    }

    pub fn host(&self) -> Option<Rc<dyn AssistantHosting>> {
        self.host.upgrade()
    }

    /// The view actually in front. A request for a view that no longer exists —
    /// because the package that declared it was disabled or removed — falls back
    /// to the workbench instead of leaving the window on nothing.
    pub fn view(&self) -> EditorStudioView {
        let requested = self.state.borrow().requested_view.clone();
        let available = (self.available_views)();
        if requested == EditorStudioView::agent()
            && !available.contains(&EditorStudioView::agent())
            && let Some(contributed) = available
                .iter()
                .find(|view| **view != EditorStudioView::make())
        {
            return contributed.clone();
        }
        if available.contains(&requested) {
            requested
        } else {
            EditorStudioView::make()
        }
    }

    pub fn show(&self, view: EditorStudioView) {
        // Asking for a view no enabled package declares would leave a request
        // that only takes effect if the package comes back; refuse it so the
        // window cannot reopen on a view that does not exist.
        let available = (self.available_views)();
        let target = if view == EditorStudioView::agent() {
            available
                .iter()
                .find(|candidate| **candidate != EditorStudioView::make())
                .cloned()
                .unwrap_or_else(|| view.clone())
        } else {
            view
        };
        if !available.contains(&target) {
            return;
        }
        self.update(|state| state.requested_view = target);
    }

    pub fn show_canvas(&self, canvas: EditorAssistantCanvas) {
        self.update(|state| state.canvas = canvas);
    }

    pub fn regions(&self) -> EditorAssistantRegions {
        let view = self.view();
        self.state
            .borrow()
            .regions
            .get(&view)
            .cloned()
            .unwrap_or_else(EditorAssistantRegions::new)
    }

    pub fn toggle_region(&self, leading: bool) {
        let view = self.view();
        self.update(|state| {
            let regions = state
                .regions
                .entry(view)
                .or_insert_with(EditorAssistantRegions::new);
            if leading {
                regions.leading = !regions.leading;
            } else {
                regions.trailing = !regions.trailing;
            }
        });
    }

    pub fn select_region_panel(&self, id: impl Into<String>, slot: impl Into<String>) {
        let view = self.view();
        let id = id.into();
        let slot = slot.into();
        self.update(|state| {
            let regions = state
                .regions
                .entry(view)
                .or_insert_with(EditorAssistantRegions::new);
            regions.selected_panels.insert(slot, id);
        });
    }

    /// Called before the bundled packages start registering. Until
    /// `finish_launch()` the window paints the launch surface rather than an
    /// editor whose views and theme are not known yet.
    pub fn begin_launch(&self) {
        self.update(|state| state.is_ready = false);
    }

    /// Called once every bundled package has registered its contributions — or
    /// once startup has given up on them.
    pub fn finish_launch(&self) {
        self.update(|state| state.is_ready = true);
    }

    /// Cycles through whatever views exist, so a third view needs no change here.
    pub fn toggle_view(&self) {
        let views = (self.available_views)();
        if views.len() <= 1 {
            return;
        }
        let current = self.view();
        let index = views.iter().position(|view| *view == current).unwrap_or(0);
        self.show(views[(index + 1) % views.len()].clone());
    }

    /// The composer lives in the agent view, so asking brings it to the front.
    pub fn focus(&self) {
        if !(self.available_views)().contains(&EditorStudioView::agent()) {
            return;
        }
        self.update(|state| {
            state.requested_view = EditorStudioView::agent();
            state.focus_request = state.focus_request.wrapping_add(1);
        });
    }

    pub fn draft(&self) -> TextBuffer {
        self.draft.borrow().clone()
    }

    pub fn set_draft(&self, draft: TextBuffer) {
        *self.draft.borrow_mut() = draft;
    }

    fn update(&self, change: impl FnOnce(&mut EditorAssistantSurfaceState)) {
        let mut next = self.state.borrow().clone();
        change(&mut next);
        if next == *self.state.borrow() {
            return;
        }
        *self.state.borrow_mut() = next;
        self.publisher.send();
    }

    pub fn register_observer(&self, handler: Rc<dyn Fn()>) -> u64 {
        self.publisher.register_observer(handler)
    }

    pub fn unregister_observer(&self, token: u64) {
        self.publisher.unregister_observer(token);
    }
}
