//! Surface behaviour for `Editor/Sources/EditorUI/ai/Surface.swift`.

use std::cell::RefCell;
use std::rc::{Rc, Weak};

use diffuse_editor_core::state::editor_store::EditorStore;
use diffuse_editor_core::workstation::documents::EditorDocumentWorkspace;

use crate::ai::assistant_hosting::{AssistantHosting, EditorStudioViewSegment};
use crate::ai::surface::{EditorAssistantCanvas, EditorAssistantSurface, EditorStudioView};

struct FakeState {
    store: EditorStore,
    views: RefCell<Vec<EditorStudioView>>,
    surface: RefCell<Weak<EditorAssistantSurface>>,
}

struct FakeHost {
    state: Rc<FakeState>,
}

impl FakeHost {
    fn new(views: Vec<EditorStudioView>) -> Rc<FakeHost> {
        Rc::new(FakeHost {
            state: Rc::new(FakeState {
                store: EditorStore::new(),
                views: RefCell::new(views),
                surface: RefCell::new(Weak::new()),
            }),
        })
    }
}

impl AssistantHosting for FakeHost {
    fn store(&self) -> &EditorStore {
        &self.state.store
    }

    fn assistant_surface(&self) -> Rc<EditorAssistantSurface> {
        self.state
            .surface
            .borrow()
            .upgrade()
            .expect("test surface is attached")
    }

    fn studio_views(&self) -> Vec<EditorStudioView> {
        self.state.views.borrow().clone()
    }

    fn studio_view_segments(&self) -> Vec<EditorStudioViewSegment> {
        self.studio_views()
            .into_iter()
            .map(|view| EditorStudioViewSegment::new(view, "title", None))
            .collect()
    }

    fn is_agent_enabled(&self) -> bool {
        true
    }

    fn is_ai_available(&self) -> bool {
        true
    }

    fn is_scene_authoring_enabled(&self) -> bool {
        true
    }

    fn documents(&self) -> Option<&EditorDocumentWorkspace> {
        None
    }

    fn submit_natural_language_intent(&self, _text: &str) -> bool {
        true
    }

    fn cancel_agent_task(&self) {}

    fn open_assistant_settings(&self) {}
}

fn host_with_surface(views: Vec<EditorStudioView>) -> Rc<dyn AssistantHosting> {
    let concrete = FakeHost::new(views);
    let host: Rc<dyn AssistantHosting> = concrete.clone();
    let surface = EditorAssistantSurface::of(&host);
    *concrete.state.surface.borrow_mut() = Rc::downgrade(&surface);
    host
}

/// A contributed view becomes the default when the host names no agent view.
#[test]
fn contributed_view_is_default() {
    let host = host_with_surface(vec![
        EditorStudioView::make(),
        EditorStudioView::new("studio.x"),
    ]);
    let surface = EditorAssistantSurface::of(&host);
    assert_eq!(surface.view(), EditorStudioView::new("studio.x"));

    surface.show(EditorStudioView::make());
    assert_eq!(surface.view(), EditorStudioView::make());
    surface.toggle_view();
    assert_eq!(surface.view(), EditorStudioView::new("studio.x"));
    EditorAssistantSurface::release(&host);
}

/// Focus only works with an agent view and bumps the request counter.
#[test]
fn focus_requires_agent_view() {
    let plain = host_with_surface(vec![EditorStudioView::make()]);
    let surface = EditorAssistantSurface::of(&plain);
    surface.focus();
    assert_eq!(surface.state().focus_request, 0);
    EditorAssistantSurface::release(&plain);

    let host = host_with_surface(vec![EditorStudioView::make(), EditorStudioView::agent()]);
    let surface = EditorAssistantSurface::of(&host);
    let observed = Rc::new(RefCell::new(0));
    let counter = observed.clone();
    let token = surface.register_observer(Rc::new(move || *counter.borrow_mut() += 1));
    surface.focus();
    assert_eq!(surface.state().requested_view, EditorStudioView::agent());
    assert_eq!(surface.state().focus_request, 1);
    assert_eq!(*observed.borrow(), 1);
    surface.unregister_observer(token);
    EditorAssistantSurface::release(&host);
}

/// Regions default open on the view they were first read in and remember panels.
#[test]
fn regions_and_panels() {
    let host = host_with_surface(vec![EditorStudioView::make(), EditorStudioView::agent()]);
    let surface = EditorAssistantSurface::of(&host);
    surface.show(EditorStudioView::make());
    assert!(surface.regions().leading);
    assert!(!surface.regions().trailing);
    surface.toggle_region(true);
    assert!(!surface.regions().leading);
    surface.toggle_region(false);
    assert!(surface.regions().trailing);
    surface.select_region_panel("panel.a", "leading");
    assert_eq!(
        surface.regions().selected_panels.get("leading"),
        Some(&"panel.a".to_string())
    );
    surface.show(EditorStudioView::agent());
    assert!(surface.regions().leading);
    EditorAssistantSurface::release(&host);
}

/// Launch readiness and canvas follow the same state.
#[test]
fn launch_and_canvas() {
    let host = host_with_surface(vec![EditorStudioView::make(), EditorStudioView::agent()]);
    let surface = EditorAssistantSurface::of(&host);
    assert!(surface.state().is_ready);
    surface.begin_launch();
    assert!(!surface.state().is_ready);
    surface.finish_launch();
    assert!(surface.state().is_ready);
    surface.show_canvas(EditorAssistantCanvas::Content(
        diffuse_editor_core::state::workspace::content::EditorContent::Files,
    ));
    assert_eq!(
        surface.state().canvas,
        EditorAssistantCanvas::Content(
            diffuse_editor_core::state::workspace::content::EditorContent::Files
        )
    );
    EditorAssistantSurface::release(&host);
}

/// A released host gets a fresh surface next time.
#[test]
fn release_drops_the_surface() {
    let host = host_with_surface(vec![EditorStudioView::make()]);
    let surface = EditorAssistantSurface::of(&host);
    let weak = Rc::downgrade(&surface);
    drop(surface);
    assert!(weak.upgrade().is_none());
    EditorAssistantSurface::release(&host);
}
