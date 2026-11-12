//! Ported from `Editor/Tests/EditorAppTests/CommitOnBlurTextFieldTests.swift`.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use cove_platform::KeyEvent;
use cove_ui_compose::prelude::LayoutFrameExt;
use cove_ui_compose::scene_core::{
    Binding, ComponentSourceLocation, EventPhase, FocusChain, FocusChainHolder,
    InteractionRegistry, InteractionRegistryHolder, Node, NodeTree, Recomposer,
    TextInputAttachmentKey, TextInputFocusChangeHandler,
};
use cove_ui_compose::{Scancode, ViewGraph};

use crate::panels::shared::commit_on_blur_text_field::CommitOnBlurTextField;

struct Model {
    value: RefCell<String>,
    writes: Cell<usize>,
}

impl Model {
    fn new() -> Self {
        Model {
            value: RefCell::new("Cube".to_string()),
            writes: Cell::new(0),
        }
    }
}

struct Rig {
    registry: Rc<InteractionRegistry>,
    node: Node,
    focus_handler: TextInputFocusChangeHandler,
    _graph: Rc<ViewGraph>,
}

fn make_binding(model: Rc<Model>) -> Binding<String> {
    let read = model.clone();
    let write = model;
    Binding::new(
        move || read.value.borrow().clone(),
        move |next: String| {
            write.writes.set(write.writes.get() + 1);
            // Model-side invariant, e.g. entity names can't be empty.
            *write.value.borrow_mut() = if next.is_empty() {
                "Entity 1".to_string()
            } else {
                next
            };
        },
    )
}

fn install(model: Rc<Model>, mixed: bool) -> Option<Rig> {
    let registry = Rc::new(InteractionRegistry::new());
    let focus = Rc::new(FocusChain::new());
    InteractionRegistryHolder::set_current(Some(registry.clone()));
    FocusChainHolder::set_current(Some(focus.clone()));

    let mut widget = CommitOnBlurTextField::new("e1/name", make_binding(model));
    if mixed {
        widget = widget.mixed_value_label("Mixed value");
    }
    let tree = Rc::new(RefCell::new(NodeTree::new()));
    let graph = Rc::new(ViewGraph::new(tree.clone(), Rc::new(Recomposer::new())));
    graph.install(
        widget.frame_size(160.0, 24.0),
        ComponentSourceLocation::default(),
    );
    graph.compute_layout(160.0, 24.0);

    let node = first_node(tree.borrow().root().as_ref(), &|node| {
        node.attachment::<TextInputFocusChangeHandler>(TextInputAttachmentKey::FOCUS_CHANGE_HANDLER)
            .is_some()
    })?;
    let focus_handler = node
        .attachment::<TextInputFocusChangeHandler>(TextInputAttachmentKey::FOCUS_CHANGE_HANDLER)?;
    Some(Rig {
        registry,
        node,
        focus_handler,
        _graph: graph,
    })
}

fn first_node(root: Option<&Node>, predicate: &impl Fn(&Node) -> bool) -> Option<Node> {
    let root = root?;
    if predicate(root) {
        return Some(root.clone());
    }
    for child in root.children() {
        if let Some(found) = first_node(Some(&child), predicate) {
            return Some(found);
        }
    }
    None
}

fn tear_down_holders() {
    InteractionRegistryHolder::set_current(None);
    FocusChainHolder::set_current(None);
}

fn key(scancode: u32, modifiers: cove_platform::KeyModifiers) -> KeyEvent {
    KeyEvent {
        scancode,
        keycode: 0,
        modifiers,
        is_repeat: false,
    }
}

/// Clearing the text mid-edit keeps the draft empty; fallback applies once on
/// blur.
#[test]
fn empty_draft_commits_on_blur() {
    let model = Rc::new(Model::new());
    let Some(rig) = install(model.clone(), false) else {
        panic!("no text field node");
    };
    let handlers = rig.registry.handlers(&rig.node);

    (rig.focus_handler)(true);
    let _ = (handlers.key.as_ref().expect("key handler"))(
        &key(Scancode::A, cove_platform::KeyModifiers::LEFT_GUI),
        EventPhase::Target,
    );
    let _ = (handlers.key.as_ref().expect("key handler"))(
        &key(Scancode::BACKSPACE, cove_platform::KeyModifiers(0)),
        EventPhase::Target,
    );

    // Mid-edit: nothing written through, no fallback generated under the caret.
    assert_eq!(model.writes.get(), 0);
    assert_eq!(*model.value.borrow(), "Cube");

    (rig.focus_handler)(false);
    // Blur commits exactly once; the model's empty-name fallback applies now.
    assert_eq!(model.writes.get(), 1);
    assert_eq!(*model.value.borrow(), "Entity 1");
    tear_down_holders();
}

/// Return commits the draft once and keeps the value editable.
#[test]
fn return_commits() {
    let model = Rc::new(Model::new());
    let Some(rig) = install(model.clone(), false) else {
        panic!("no text field node");
    };
    let handlers = rig.registry.handlers(&rig.node);

    (rig.focus_handler)(true);
    let _ = (handlers.key.as_ref().expect("key handler"))(
        &key(Scancode::A, cove_platform::KeyModifiers::LEFT_GUI),
        EventPhase::Target,
    );
    let _ = (handlers.text.as_ref().expect("text handler"))("Box", EventPhase::Target);
    assert_eq!(model.writes.get(), 0);

    let _ = (handlers.key.as_ref().expect("key handler"))(
        &key(Scancode::RETURN, cove_platform::KeyModifiers(0)),
        EventPhase::Target,
    );
    assert_eq!(model.writes.get(), 1);
    assert_eq!(*model.value.borrow(), "Box");

    // Typing again after a Return-commit re-enters draft mode.
    let _ = (handlers.text.as_ref().expect("text handler"))("y", EventPhase::Target);
    assert_eq!(model.writes.get(), 1);
    (rig.focus_handler)(false);
    assert_eq!(model.writes.get(), 2);
    assert_eq!(*model.value.borrow(), "Boxy");
    tear_down_holders();
}

/// A mixed field does not commit on focus and blur, but accepts the primary
/// object's value.
#[test]
fn mixed_draft() {
    let model = Rc::new(Model::new());
    let rig = install(model.clone(), true).expect("text field node");
    (rig.focus_handler)(true);
    (rig.focus_handler)(false);
    assert_eq!(model.writes.get(), 0);

    let handlers = rig.registry.handlers(&rig.node);
    (rig.focus_handler)(true);
    let _ = (handlers.text.as_ref().expect("text handler"))("Cube", EventPhase::Target);
    (rig.focus_handler)(false);
    assert_eq!(model.writes.get(), 1);
    assert_eq!(*model.value.borrow(), "Cube");
    tear_down_holders();
}
