//! Translation of Editor/Sources/EditorUI/Shell/Appearance.swift.

use cove_ui_compose::modifiers::animation_value::AnimationValueExt;
use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::scene_core::{Align, Color, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::styles::buttons::button_style::{
    ButtonStyle, ButtonStyleConfiguration,
};
use cove_ui_compose::theme::{SemanticFontRef, SemanticMotionRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, BoxView, FrameDimension};
use diffuse_editor_core::contributions::themes::editor_theme_tokens::EditorThemeTokens;

/// Shared, bounded controls for the title bar, activity rail and context header.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EditorChromeButtonStyle {
    pub height: f32,
    pub agent: bool,
}

impl Default for EditorChromeButtonStyle {
    fn default() -> Self {
        EditorChromeButtonStyle {
            height: 26.0,
            agent: false,
        }
    }
}

impl EditorChromeButtonStyle {
    pub fn new(height: f32) -> Self {
        EditorChromeButtonStyle {
            height,
            agent: false,
        }
    }
}

impl ButtonStyle for EditorChromeButtonStyle {
    fn make_body(&self, configuration: ButtonStyleConfiguration) -> AnyView {
        let theme = &configuration.theme;
        let colors = theme.colors;
        let ink = if self.agent {
            theme.extensions.get::<EditorThemeTokens>().assistant
        } else {
            colors.on_surface
        };
        let foreground = if !configuration.is_enabled {
            colors.on_surface_muted
        } else if configuration.is_selected || self.agent {
            ink
        } else {
            colors.on_surface_variant
        };
        let label = AnyView::new(configuration.label.clone())
            .semantic_font(SemanticFontRef::label())
            .foreground_color(foreground);
        let background = if configuration.is_pressed {
            colors.state_layer_pressed
        } else if configuration.is_selected {
            colors.surface_variant
        } else if configuration.is_hovered {
            colors.state_layer_hover
        } else {
            Color::CLEAR
        };
        AnyView::new(
            AnyView::new(BoxView::new(
                FlexDirection::Row,
                Align::Center,
                Justify::Center,
                Wrap::NoWrap,
                0.0,
                AnyView::new(label),
            ))
            .padding_edges(8.0, 0.0)
            .frame(
                None,
                Some(FrameDimension::Points(self.height)),
                Some(self.height),
                None,
                None,
                None,
            )
            .background_color(background)
            .corner_radius(6.0)
            .border_color(
                if configuration.is_focused {
                    colors.focus_ring
                } else {
                    Color::CLEAR
                },
                1.0,
            )
            .animation_motion(SemanticMotionRef::fast(), configuration.interaction_key()),
        )
    }
}
