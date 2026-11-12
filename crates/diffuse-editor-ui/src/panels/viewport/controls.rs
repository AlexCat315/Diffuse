//! Translation of Editor/Sources/EditorUI/Panels/Viewport/Controls.swift.
//!
//! Menu affordances are explicit and remain stable when the value changes.

use cove_platform::KeyEvent;
use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::modifiers::interaction::HoverExt;
use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::media::Icon;
use cove_ui_compose::primitives::media::ui_icon_catalog;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{EventPhase, EventResult};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, Row, Scancode, Scope, Signal, TupleView, VerticalAlignment, View};

pub struct ViewportMenuTrigger {
    pub icon: Option<BundleImageResource>,
    pub label: Option<String>,
    pub is_active: bool,
    pub is_compact: bool,
}

impl ViewportMenuTrigger {
    pub fn new(
        icon: Option<BundleImageResource>,
        label: Option<String>,
        is_active: bool,
        is_compact: bool,
    ) -> Self {
        ViewportMenuTrigger {
            icon,
            label,
            is_active,
            is_compact,
        }
    }
}

impl View for ViewportMenuTrigger {
    fn body(&self, scope: &Scope) -> AnyView {
        let is_hovered = scope.state(|| false);
        let mut children: Vec<AnyView> = Vec::new();
        if let Some(icon) = &self.icon {
            children.push(AnyView::new(Icon::with_semantic(
                icon.clone(),
                14.0,
                if self.is_active {
                    SemanticColorRef::accent()
                } else {
                    SemanticColorRef::on_surface_variant()
                },
            )));
        }
        if let Some(label) = &self.label {
            children.push(AnyView::new(
                Text::new(label.clone())
                    .line_limit(Some(1))
                    .semantic_font(SemanticFontRef::label())
                    .semantic_foreground(if self.is_active {
                        SemanticColorRef::accent()
                    } else {
                        SemanticColorRef::on_surface()
                    }),
            ));
            children.push(AnyView::new(Icon::with_semantic(
                ui_icon_catalog::navigation::chevron_down(),
                9.0,
                SemanticColorRef::on_surface_muted(),
            )));
        }
        let horizontal = match (self.label.is_some(), self.is_compact) {
            (false, _) => 7.0,
            (true, true) => 6.0,
            (true, false) => 10.0,
        };
        let background = if self.is_active {
            SemanticColorRef::accent_muted()
        } else if is_hovered.get() {
            SemanticColorRef::state_layer_hover()
        } else {
            SemanticColorRef::clear()
        };
        let hovered = is_hovered;
        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                6.0,
                AnyView::new(TupleView::new(children)),
            )
            .padding_edges(horizontal, 0.0)
            .frame_height(28.0)
            .semantic_background(background)
            .corner_radius(7.0)
            .on_hover(move |is_hovered| hovered.set(is_hovered)),
        )
    }
}

/// Escape closes a viewport popover while it has focus.
pub fn viewport_popover_dismiss_on_escape(
    is_presented: Signal<bool>,
) -> impl Fn(&KeyEvent, EventPhase) -> EventResult + 'static {
    move |event, phase| {
        if (phase == EventPhase::Target || phase == EventPhase::Bubble)
            && event.scancode == Scancode::ESCAPE
        {
            is_presented.set(false);
            EventResult::Handled
        } else {
            EventResult::Ignored
        }
    }
}
