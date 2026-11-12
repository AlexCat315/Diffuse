//! Ported from `Editor/Tests/EditorCoreTests/Rendering/ViewportHostInputTests.swift`.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use cove_platform::{InputEvent, KeyEvent, KeyModifiers, MouseButton, MouseButtonEvent, WindowId};
use cove_ui_compose::prelude::LayoutFrameExt;
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::overlays::ShortcutHost;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{
    Align, ComponentSourceLocation, EventDispatcher, FlexDirection, FocusChain, FocusChainHolder,
    InteractionRegistry, InteractionRegistryHolder, Justify, NodeTree, PointerCapture,
    PointerCaptureHolder, Recomposer, Wrap,
};
use cove_ui_compose::{AnyView, BoxView, ViewGraph};

use crate::rendering::viewport::viewport_host::ViewportHost;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

struct Holders {
    registry: Rc<InteractionRegistry>,
    capture: Rc<PointerCapture>,
    focus: Rc<FocusChain>,
}

impl Holders {
    fn install() -> Self {
        let holders = Holders {
            registry: Rc::new(InteractionRegistry::new()),
            capture: Rc::new(PointerCapture::new()),
            focus: Rc::new(FocusChain::new()),
        };
        InteractionRegistryHolder::set_current(Some(holders.registry.clone()));
        FocusChainHolder::set_current(Some(holders.focus.clone()));
        PointerCaptureHolder::set_current(Some(holders.capture.clone()));
        holders
    }
}

impl Drop for Holders {
    fn drop(&mut self) {
        InteractionRegistryHolder::set_current(None);
        FocusChainHolder::set_current(None);
        PointerCaptureHolder::set_current(None);
    }
}

fn dispatcher(tree: &Rc<RefCell<NodeTree>>, holders: &Holders) -> EventDispatcher {
    EventDispatcher::new(
        tree.clone(),
        holders.registry.clone(),
        holders.capture.clone(),
        holders.focus.clone(),
        WindowId::MAIN,
    )
}

fn mouse_event(x: f32, y: f32) -> MouseButtonEvent {
    MouseButtonEvent {
        button: MouseButton::Left,
        x,
        y,
        clicks: 1,
        modifiers: KeyModifiers(0),
        kind: Default::default(),
    }
}

/// Overlay controls receive pointer events without forwarding them to viewport input.
#[test]
fn overlay_control_does_not_trigger_viewport_input() {
    let holders = Holders::install();

    let viewport_events: Rc<RefCell<Vec<InputEvent>>> = Rc::new(RefCell::new(Vec::new()));
    let event_sink = viewport_events.clone();
    let button_taps = Rc::new(Cell::new(0usize));
    let tap_sink = button_taps.clone();

    let button = Button::new(Text::new("Rotate"), move || {
        tap_sink.set(tap_sink.get() + 1);
    })
    .frame_size(80.0, 28.0);
    let host = ViewportHost::new(ViewportSurfaceState::default(), button)
        .on_input_event(Rc::new(move |event| event_sink.borrow_mut().push(event)))
        .frame_size(200.0, 120.0);

    let tree = Rc::new(RefCell::new(NodeTree::new()));
    let graph = Rc::new(ViewGraph::new(tree.clone(), Rc::new(Recomposer::new())));
    graph.install(host, ComponentSourceLocation::default());
    graph.compute_layout(200.0, 120.0);

    let dispatcher = dispatcher(&tree, &holders);
    let event = mouse_event(12.0, 12.0);
    dispatcher.dispatch(&InputEvent::MouseButtonDown(event.clone()));
    dispatcher.dispatch(&InputEvent::MouseButtonUp(event));

    assert_eq!(button_taps.get(), 1);
    assert!(viewport_events.borrow().is_empty());
}

/// Focused viewport consumes raw keys but lets command chords reach shortcuts.
#[test]
fn command_chords_fall_through_to_shortcuts() {
    let holders = Holders::install();

    let viewport_events: Rc<RefCell<Vec<InputEvent>>> = Rc::new(RefCell::new(Vec::new()));
    let event_sink = viewport_events.clone();
    let shortcut_keys: Rc<RefCell<Vec<KeyEvent>>> = Rc::new(RefCell::new(Vec::new()));
    let shortcut_sink = shortcut_keys.clone();

    let shortcuts = ShortcutHost::new(move |key| {
        shortcut_sink.borrow_mut().push(key.clone());
        true
    });
    let host = ViewportHost::without_overlay(ViewportSurfaceState::default())
        .on_input_event(Rc::new(move |event| event_sink.borrow_mut().push(event)))
        .frame_size(200.0, 120.0);
    let root = BoxView::new(
        FlexDirection::Column,
        Align::Stretch,
        Justify::FlexStart,
        Wrap::NoWrap,
        0.0,
        AnyView::new(cove_ui_compose::TupleView::new(vec![
            AnyView::new(shortcuts),
            AnyView::new(host),
        ])),
    )
    .frame_size(200.0, 120.0);

    let tree = Rc::new(RefCell::new(NodeTree::new()));
    let graph = Rc::new(ViewGraph::new(tree.clone(), Rc::new(Recomposer::new())));
    graph.install(root, ComponentSourceLocation::default());
    graph.compute_layout(200.0, 120.0);

    let dispatcher = dispatcher(&tree, &holders);
    // Click into the viewport so it grabs keyboard focus.
    let click = mouse_event(100.0, 60.0);
    dispatcher.dispatch(&InputEvent::MouseButtonDown(click.clone()));
    dispatcher.dispatch(&InputEvent::MouseButtonUp(click));
    assert!(holders.focus.focused().is_some());

    let plain_s = KeyEvent {
        scancode: 22,
        keycode: 0x73,
        modifiers: KeyModifiers(0),
        is_repeat: false,
    };
    dispatcher.dispatch(&InputEvent::KeyDown(plain_s.clone()));
    assert!(shortcut_keys.borrow().is_empty());

    let command_s = KeyEvent {
        scancode: plain_s.scancode,
        keycode: plain_s.keycode,
        modifiers: KeyModifiers::LEFT_GUI,
        is_repeat: false,
    };
    dispatcher.dispatch(&InputEvent::KeyDown(command_s));
    let shortcuts = shortcut_keys.borrow();
    assert_eq!(shortcuts.len(), 1);
    assert_eq!(shortcuts[0].scancode, 22);

    // The viewport still sees both keys for pressed-state bookkeeping.
    let key_downs = viewport_events
        .borrow()
        .iter()
        .filter(|event| matches!(event, InputEvent::KeyDown(_)))
        .count();
    assert_eq!(key_downs, 2);
}
