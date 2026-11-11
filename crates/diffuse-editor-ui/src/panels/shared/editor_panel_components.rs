//! Translation of
//! Editor/Sources/EditorUI/Panels/Shared/EditorPanelComponents.swift.
//!
//! Shared editor-panel chrome. Keeping density, insets and surface in one place
//! makes docked panels feel like parts of one application instead of unrelated
//! tools.

use std::rc::Rc;

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::modifiers::animation_value::AnimationValueExt;
use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::controls::{Button, ButtonIconSource};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use cove_ui_compose::primitives::text::text_field::TextField;
use cove_ui_compose::primitives::text::text_field::text_field::TextFieldEvents;
use cove_ui_compose::primitives::text::text_field::text_field_options::{
    TextFieldBehavior, TextFieldDecoration, TextFieldSize,
};
use cove_ui_compose::scene_core::{Align, Binding, Color, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ToggleButtonStyle};
use cove_ui_compose::theme::styles::components::tree_row_style::{
    TreeRowStyle, TreeRowStyleConfiguration,
};
use cove_ui_compose::theme::{
    SemanticColorRef, SemanticFontRef, SemanticMotionRef, SemanticStyleViewExt,
};
use cove_ui_compose::{
    AnyView, BoxView, EmptyView, Row, Scope, TupleView, VerticalAlignment, View,
};

pub struct EditorPanelToolbar<Content: View + Clone + 'static> {
    pub content: Content,
    pub spacing: f32,
}

impl<Content: View + Clone + 'static> EditorPanelToolbar<Content> {
    pub fn new(content: Content, spacing: f32) -> Self {
        EditorPanelToolbar { content, spacing }
    }
}

impl<Content: View + Clone + 'static> View for EditorPanelToolbar<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                self.spacing,
                AnyView::new(self.content.clone()),
            )
            .padding_edges(8.0, 2.0)
            .frame_height(32.0)
            .semantic_background(SemanticColorRef::surface()),
        )
    }
}

pub struct EditorPanelSearchBar {
    pub placeholder: String,
    pub text: Binding<TextBuffer>,
    pub summary: Option<String>,
    pub on_submit: Option<Rc<dyn Fn()>>,
    pub on_cancel: Option<Rc<dyn Fn()>>,
    pub actions: AnyView,
    pub leading: Option<AnyView>,
}

impl EditorPanelSearchBar {
    /// Swift's `init(_:text:summary:onSubmit:onCancel:leading:actions:)`.
    pub fn with_actions(
        placeholder: impl Into<String>,
        text: Binding<TextBuffer>,
        summary: Option<String>,
        on_submit: Option<Rc<dyn Fn()>>,
        on_cancel: Option<Rc<dyn Fn()>>,
        leading: Option<AnyView>,
        actions: AnyView,
    ) -> Self {
        EditorPanelSearchBar {
            placeholder: placeholder.into(),
            text,
            summary,
            on_submit,
            on_cancel,
            actions,
            leading,
        }
    }

    /// Swift's convenience initializer without a leading view or actions.
    pub fn new(placeholder: impl Into<String>, text: Binding<TextBuffer>) -> Self {
        Self::with_actions(
            placeholder,
            text,
            None,
            None,
            None,
            None,
            AnyView::new(EmptyView),
        )
    }
}

impl View for EditorPanelSearchBar {
    fn body(&self, _scope: &Scope) -> AnyView {
        let mut children: Vec<AnyView> = Vec::new();
        if let Some(leading) = self.leading.clone() {
            children.push(leading);
        }
        let events = TextFieldEvents {
            on_submit: self.on_submit.clone(),
            on_cancel: self.on_cancel.clone(),
            ..TextFieldEvents::default()
        };
        let field = TextField::new(self.placeholder.clone(), self.text.clone())
            .decoration(TextFieldDecoration {
                size: TextFieldSize::Small,
                ..TextFieldDecoration::default()
            })
            .behavior(TextFieldBehavior {
                clearable: true,
                ..TextFieldBehavior::default()
            })
            .events(events);
        children.push(AnyView::new(
            field.semantic_font(SemanticFontRef::caption()).flex(1.0),
        ));
        if let Some(summary) = self.summary.clone()
            && !summary.is_empty()
        {
            children.push(AnyView::new(EditorPanelBadge::new(
                summary,
                SemanticColorRef::on_surface_variant(),
            )));
        }
        children.push(self.actions.clone());

        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                6.0,
                AnyView::new(TupleView::new(children)),
            )
            .padding_edges(8.0, 2.0)
            .frame_height(32.0)
            .semantic_background(SemanticColorRef::surface()),
        )
    }
}

pub struct EditorPanelBadge {
    pub text: String,
    pub foreground: SemanticColorRef,
}

impl EditorPanelBadge {
    pub fn new(text: impl Into<String>, foreground: SemanticColorRef) -> Self {
        EditorPanelBadge {
            text: text.into(),
            foreground,
        }
    }

    /// Swift's `init(_:foreground: .onSurfaceVariant)` default.
    pub fn with_default_foreground(text: impl Into<String>) -> Self {
        Self::new(text, SemanticColorRef::on_surface_variant())
    }
}

impl View for EditorPanelBadge {
    fn body(&self, _scope: &Scope) -> AnyView {
        AnyView::new(
            AnyView::new(BoxView::new(
                FlexDirection::Row,
                Align::Center,
                Justify::Center,
                Wrap::NoWrap,
                0.0,
                AnyView::new(
                    Text::new(self.text.clone())
                        .line_limit(Some(1))
                        .semantic_font(SemanticFontRef::caption())
                        .semantic_foreground(self.foreground.clone()),
                ),
            ))
            .padding_edges(5.0, 1.0)
            .semantic_background(SemanticColorRef::surface_variant())
            .corner_radius(4.0),
        )
    }
}

/// Empty and zero-result state shared by editor panels.
pub struct EditorPanelEmptyState {
    pub title: String,
    pub detail: Option<String>,
}

impl EditorPanelEmptyState {
    pub fn new(title: impl Into<String>, detail: Option<String>) -> Self {
        EditorPanelEmptyState {
            title: title.into(),
            detail,
        }
    }

    pub fn without_detail(title: impl Into<String>) -> Self {
        Self::new(title, None)
    }
}

impl View for EditorPanelEmptyState {
    fn body(&self, _scope: &Scope) -> AnyView {
        let mut children: Vec<AnyView> = vec![AnyView::new(
            Text::new(self.title.clone())
                .semantic_font(SemanticFontRef::body_strong())
                .semantic_foreground(SemanticColorRef::on_surface()),
        )];
        if let Some(detail) = self.detail.clone()
            && !detail.is_empty()
        {
            children.push(AnyView::new(
                Text::new(detail)
                    .alignment(cove_ui_compose::scene_core::TextAlignment::Center)
                    .semantic_font(SemanticFontRef::caption())
                    .semantic_foreground(SemanticColorRef::on_surface_muted())
                    .frame(None, None, None, None, Some(280.0), None),
            ));
        }
        AnyView::new(
            AnyView::new(BoxView::new(
                FlexDirection::Column,
                Align::Center,
                Justify::Center,
                Wrap::NoWrap,
                6.0,
                AnyView::new(TupleView::new(children)),
            ))
            .padding_edges(16.0, 16.0),
        )
    }
}

/// Reusable icon-only action used by compact panel toolbars.
pub struct EditorPanelIconButton {
    pub icon: BundleImageResource,
    pub tooltip: String,
    pub is_enabled: bool,
    pub action: Rc<dyn Fn()>,
}

impl EditorPanelIconButton {
    pub fn new(
        icon: BundleImageResource,
        tooltip: impl Into<String>,
        is_enabled: bool,
        action: impl Fn() + 'static,
    ) -> Self {
        EditorPanelIconButton {
            icon,
            tooltip: tooltip.into(),
            is_enabled,
            action: Rc::new(action),
        }
    }

    /// Swift's `isEnabled: true` default.
    pub fn enabled(
        icon: BundleImageResource,
        tooltip: impl Into<String>,
        action: impl Fn() + 'static,
    ) -> Self {
        Self::new(icon, tooltip, true, action)
    }
}

impl View for EditorPanelIconButton {
    fn body(&self, _scope: &Scope) -> AnyView {
        let action = self.action.clone();
        AnyView::new(
            Button::icon_with_options(
                ButtonIconSource::resource(self.icon.clone()),
                Some(11.0),
                None,
                cove_ui_compose::primitives::controls::ButtonRole::Normal,
                self.is_enabled,
                false,
                false,
                Some(self.tooltip.clone()),
                move || action(),
            )
            .button_style(ToggleButtonStyle::new(0.0, 22.0)),
        )
    }
}

/// Row chrome shared by the outline and file trees: an inset rounded pill,
/// like the tabs, with a soft accent tint for the selection.
pub struct EditorTreeRowStyle;

impl TreeRowStyle for EditorTreeRowStyle {
    fn make_body(&self, configuration: TreeRowStyleConfiguration) -> AnyView {
        let theme = &configuration.theme;
        let background: Color = if configuration.is_selected {
            theme.colors.accent_muted
        } else if configuration.is_search_hit {
            theme.colors.state_layer_selected
        } else if configuration.is_hovered {
            theme.colors.state_layer_hover
        } else {
            Color::CLEAR
        };

        let row = AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                0.0,
                AnyView::new(
                    configuration
                        .content
                        .clone()
                        .flex_with(1.0, 1.0, Some(0.0))
                        .padding_edges(6.0, 0.0),
                ),
            )
            .flex_with(1.0, 1.0, Some(0.0))
            .background_color(background)
            .corner_radius(6.0)
            .clipped(),
        );
        AnyView::new(
            AnyView::new(BoxView::new(
                FlexDirection::Row,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                0.0,
                row,
            ))
            .padding_edges(6.0, 1.0)
            .opacity(if configuration.is_enabled { 1.0 } else { 0.55 })
            .animation_motion(
                SemanticMotionRef::fast(),
                [
                    configuration.is_selected,
                    configuration.is_search_hit,
                    configuration.is_hovered,
                    configuration.is_enabled,
                ],
            ),
        )
    }
}
