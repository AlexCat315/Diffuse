//! Translation of Editor/Sources/EditorUI/Root/Chrome/ModalBarrier.swift.
//!
//! Invisible full-window modal barrier: swallows pointer / wheel / hover so
//! everything behind stays inert (no visual dimming, per design preference),
//! and centers its content. Lives in the portal layer, which is absolutely
//! positioned over the whole window.

use std::rc::Rc;

use cove_ui_compose::primitives::overlays::FocusScope;
use cove_ui_compose::scene_core::{
    Align, Edge, EventPhase, EventResult, FlexDirection, InputHandlerRole, InputHandlerRoute,
    InputRoutingPriority, InteractionRegistryHolder, Justify, LayoutNode, Node, PointerPhase,
    PositionType,
};
use cove_ui_compose::{AnyView, PrimitiveView, Scope, View};

struct ModalBarrierHost<Content: View + Clone + 'static> {
    on_background_tap: Option<Rc<dyn Fn()>>,
    content: Content,
}

impl<Content: View + Clone + 'static> PrimitiveView for ModalBarrierHost<Content> {
    fn make_node(&self) -> Node {
        let node = Node::new();
        node.set_is_hit_testable(true);
        node.set_is_focusable(false);
        node
    }

    fn update_node(&self, node: &Node) {
        let Some(registry) = InteractionRegistryHolder::current() else {
            return;
        };
        let on_background_tap = self.on_background_tap.clone();
        let route = InputHandlerRoute::new(
            InputHandlerRole::Control,
            InputRoutingPriority::MODAL,
            "modal.barrier",
        );
        registry.set_pointer(
            node,
            route.clone(),
            Rc::new(move |_, pointer_phase, event_phase| {
                if event_phase != EventPhase::Target {
                    return EventResult::Ignored;
                }
                if pointer_phase == PointerPhase::Down
                    && let Some(on_background_tap) = &on_background_tap
                {
                    on_background_tap();
                }
                EventResult::Handled
            }),
        );
        registry.set_motion(
            node,
            route.clone(),
            Rc::new(|_, event_phase| {
                if event_phase == EventPhase::Target {
                    EventResult::Handled
                } else {
                    EventResult::Ignored
                }
            }),
        );
        registry.set_wheel(
            node,
            route,
            Rc::new(|_, event_phase| {
                if event_phase == EventPhase::Capture {
                    EventResult::Ignored
                } else {
                    EventResult::Handled
                }
            }),
        );
    }

    fn make_layout_node(&self) -> Option<LayoutNode> {
        Some(LayoutNode::new())
    }

    fn update_layout(&self, layout: &LayoutNode) {
        layout.set_position_type(PositionType::Absolute);
        layout.set_position(0.0, Edge::Left);
        layout.set_position(0.0, Edge::Top);
        layout.set_position(0.0, Edge::Right);
        layout.set_position(0.0, Edge::Bottom);
        layout.set_flex_direction(FlexDirection::Column);
        layout.set_align_items(Align::Center);
        layout.set_justify_content(Justify::Center);
    }

    fn children(&self, _node: &Node) -> Vec<AnyView> {
        vec![AnyView::new(self.content.clone())]
    }
}

// The macro only covers concrete types; this host stays generic so the barrier
// can wrap any content without erasing it before materialization.
impl<Content: View + Clone + 'static> View for ModalBarrierHost<Content> {
    fn kind(&self) -> cove_ui_compose::ViewKind<'_> {
        cove_ui_compose::ViewKind::Primitive(self)
    }

    fn tag(&self) -> &'static str {
        std::any::type_name::<Self>()
    }
}

pub struct ModalBarrier<Content: View + Clone + 'static> {
    pub on_background_tap: Option<Rc<dyn Fn()>>,
    pub content: Content,
}

impl<Content: View + Clone + 'static> ModalBarrier<Content> {
    pub fn new(content: Content) -> Self {
        ModalBarrier {
            on_background_tap: None,
            content,
        }
    }

    pub fn on_background_tap(mut self, handler: impl Fn() + 'static) -> Self {
        self.on_background_tap = Some(Rc::new(handler));
        self
    }
}

impl<Content: View + Clone + 'static> View for ModalBarrier<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        AnyView::new(FocusScope::new(AnyView::new(ModalBarrierHost {
            on_background_tap: self.on_background_tap.clone(),
            content: self.content.clone(),
        })))
    }
}
