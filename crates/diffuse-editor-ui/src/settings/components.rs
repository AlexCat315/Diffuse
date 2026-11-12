//! Translation of Editor/Sources/EditorUI/Settings/Components.swift.
//!
//! Shared settings chrome: the brand mark, the card every section sits in, the
//! labelled field row and the segmented choice style.

use cove_ui_compose::adaptive::ContainerSizeReader;
use cove_ui_compose::core_exports::{Color, Size};
use cove_ui_compose::modifiers::animation_value::AnimationValueExt;
use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::styles::buttons::{ButtonStyle, ButtonStyleConfiguration};
use cove_ui_compose::theme::{
    SemanticColorRef, SemanticFontRef, SemanticMotionRef, SemanticStyleViewExt,
};
use cove_ui_compose::{
    AnyView, BoxView, Column, FrameDimension, HorizontalAlignment, Scope, TupleView, View,
};

pub struct SettingsBrandMark {
    pub size: f32,
}

impl SettingsBrandMark {
    pub fn new(size: f32) -> Self {
        SettingsBrandMark { size }
    }
}

impl Default for SettingsBrandMark {
    fn default() -> Self {
        SettingsBrandMark::new(30.0)
    }
}

impl View for SettingsBrandMark {
    fn body(&self, _scope: &Scope) -> AnyView {
        let font = if self.size > 30.0 {
            SemanticFontRef::headline()
        } else {
            SemanticFontRef::body_strong()
        };
        let label = AnyView::new(
            Text::new("G")
                .semantic_font(font)
                .semantic_foreground(SemanticColorRef::on_accent()),
        );
        AnyView::new(
            BoxView::new(
                FlexDirection::Row,
                Align::Center,
                Justify::Center,
                Wrap::NoWrap,
                0.0,
                label,
            )
            .frame_size(self.size, self.size)
            .semantic_background(SemanticColorRef::accent())
            .corner_radius(self.size * 0.26),
        )
    }
}

pub struct SettingsCard<Content: View + Clone + 'static> {
    pub title: String,
    pub subtitle: String,
    pub content: Content,
}

impl<Content: View + Clone + 'static> SettingsCard<Content> {
    pub fn new(title: impl Into<String>, subtitle: impl Into<String>, content: Content) -> Self {
        SettingsCard {
            title: title.into(),
            subtitle: subtitle.into(),
            content,
        }
    }
}

impl<Content: View + Clone + 'static> View for SettingsCard<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        let mut heading: Vec<AnyView> = vec![AnyView::new(
            Text::new(self.title.clone())
                .semantic_font(SemanticFontRef::body_strong())
                .semantic_foreground(SemanticColorRef::on_surface()),
        )];
        if !self.subtitle.is_empty() {
            heading.push(AnyView::new(
                Text::new(self.subtitle.clone())
                    .semantic_font(SemanticFontRef::body())
                    .semantic_foreground(SemanticColorRef::on_surface_muted()),
            ));
        }
        let heading = AnyView::new(Column::new(
            HorizontalAlignment::Leading,
            4.0,
            AnyView::new(TupleView::new(heading)),
        ));
        AnyView::new(
            BoxView::new(
                FlexDirection::Column,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                16.0,
                AnyView::new(TupleView::new(vec![
                    heading,
                    AnyView::new(self.content.clone()),
                ])),
            )
            .padding(18.0)
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                None,
                None,
                None,
            )
            .semantic_background(SemanticColorRef::surface())
            .corner_radius(10.0),
        )
    }
}

pub struct SettingsField<Content: View + Clone + 'static> {
    pub title: String,
    pub help: String,
    pub content: Content,
}

impl<Content: View + Clone + 'static> SettingsField<Content> {
    pub fn new(title: impl Into<String>, help: impl Into<String>, content: Content) -> Self {
        SettingsField {
            title: title.into(),
            help: help.into(),
            content,
        }
    }
}

impl<Content: View + Clone + 'static> View for SettingsField<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        let title = self.title.clone();
        let help = self.help.clone();
        let content = self.content.clone();
        AnyView::new(ContainerSizeReader::new(move |size: Size| {
            let leading = size.width >= 500.0;
            let labels = AnyView::new(
                Column::new(
                    HorizontalAlignment::Leading,
                    5.0,
                    AnyView::new(TupleView::new(vec![
                        AnyView::new(
                            Text::new(title.clone())
                                .semantic_font(SemanticFontRef::label())
                                .semantic_foreground(SemanticColorRef::on_surface()),
                        ),
                        AnyView::new(
                            Text::new(help.clone())
                                .semantic_font(SemanticFontRef::body())
                                .semantic_foreground(SemanticColorRef::on_surface_muted()),
                        ),
                    ])),
                )
                .flex_with(if leading { 1.0 } else { 0.0 }, 1.0, leading.then_some(0.0))
                .frame(None, None, Some(0.0), None, None, None),
            );
            let content = AnyView::new(
                AnyView::new(content.clone())
                    .frame(None, None, Some(0.0), None, None, None)
                    .flex_with(0.0, 1.0, None),
            );
            AnyView::new(
                BoxView::new(
                    if leading {
                        FlexDirection::Row
                    } else {
                        FlexDirection::Column
                    },
                    if leading {
                        Align::Center
                    } else {
                        Align::Stretch
                    },
                    Justify::FlexStart,
                    Wrap::NoWrap,
                    14.0,
                    AnyView::new(TupleView::new(vec![labels, content])),
                )
                .frame(None, None, Some(0.0), None, None, None),
            )
        }))
    }
}

/// Selected choices use the accent pair; the rest sit on the sunken surface and
/// only light up under the pointer.
pub struct SettingsChoiceStyle;

impl ButtonStyle for SettingsChoiceStyle {
    fn make_body(&self, configuration: ButtonStyleConfiguration) -> AnyView {
        let colors = configuration.theme.colors;
        let interaction_key = configuration.interaction_key();
        let label = AnyView::new(configuration.label)
            .semantic_font(SemanticFontRef::label())
            .foreground_color(if configuration.is_selected {
                colors.accent
            } else {
                colors.on_surface_variant
            });
        let background: Color = if configuration.is_selected {
            colors.accent_muted
        } else if configuration.is_hovered {
            colors.state_layer_hover
        } else {
            colors.surface_sunken
        };
        AnyView::new(
            BoxView::new(
                FlexDirection::Row,
                Align::Center,
                Justify::Center,
                Wrap::NoWrap,
                0.0,
                AnyView::new(label),
            )
            .padding_edges(12.0, 8.0)
            .frame(None, None, None, Some(32.0), None, None)
            .background_color(background)
            .corner_radius(6.0)
            .border_color(
                if configuration.is_selected {
                    colors.accent
                } else {
                    colors.border
                },
                1.0,
            )
            .animation_motion(SemanticMotionRef::fast(), interaction_key),
        )
    }
}
