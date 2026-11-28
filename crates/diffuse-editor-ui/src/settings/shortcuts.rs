//! `Editor/Sources/EditorUI/Settings/Shortcuts.swift`.
//!
//! The keyboard shortcuts card: every catalog entry that carries a shortcut,
//! titled the way the menu titles it and labelled the way the palette labels it.
//!
//! Difference from Swift: CoveUICompose has no `Divider` primitive, so the rule
//! under each row is a one-point box filled with the theme's border colour; the
//! rest of the composition (row padding, label chip, full-width sizing) keeps
//! the Swift metrics.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, BoxView, FrameDimension, LayoutDebugExt, Scope, TupleView, View};
use diffuse_editor_core::application::editor_application::EditorApplication;

use crate::commands::catalog::{EditorCommandCatalog, EditorCommandContext, EditorCommandEntry};
use crate::localization::localized;
use crate::settings::components::SettingsCard;

pub struct ShortcutSettings {
    pub entries: Vec<EditorCommandEntry>,
}

impl ShortcutSettings {
    pub fn new(app: &Rc<EditorApplication>) -> Self {
        ShortcutSettings {
            entries: EditorCommandCatalog::make(&EditorCommandContext::from_application(app))
                .entries()
                .into_iter()
                .filter(|entry| entry.shortcut.is_some())
                .collect(),
        }
    }

    /// Title on the left, the chord on the right, then the rule under the row.
    fn row(entry: &EditorCommandEntry) -> AnyView {
        let title = AnyView::new(
            AnyView::new(
                Text::new(entry.title.clone())
                    .semantic_font(SemanticFontRef::body())
                    .semantic_foreground(SemanticColorRef::on_surface_variant()),
            )
            .flex(1.0),
        );
        let label = AnyView::new(
            Text::new(
                entry
                    .shortcut
                    .as_ref()
                    .map(|shortcut| shortcut.label())
                    .unwrap_or_default(),
            )
            .semantic_font(SemanticFontRef::mono())
            .semantic_foreground(SemanticColorRef::on_surface()),
        )
        .padding_edges(8.0, 4.0)
        .semantic_background(SemanticColorRef::surface_sunken())
        .corner_radius(5.0)
        .semantic_border(SemanticColorRef::border(), 1.0);
        let chip: AnyView = AnyView::new(label);
        let row_items: Vec<AnyView> = vec![title, chip];
        AnyView::new(
            BoxView::new(
                FlexDirection::Column,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                0.0,
                AnyView::new(TupleView::new(vec![
                    AnyView::new(
                        BoxView::new(
                            FlexDirection::Row,
                            Align::Center,
                            Justify::FlexStart,
                            Wrap::NoWrap,
                            12.0,
                            AnyView::new(TupleView::new(row_items)),
                        )
                        .padding_edges(0.0, 9.0)
                        .frame(
                            Some(FrameDimension::Percent(100.0)),
                            None,
                            Some(0.0),
                            None,
                            None,
                            None,
                        ),
                    ),
                    AnyView::new(
                        BoxView::new(
                            FlexDirection::Row,
                            Align::Stretch,
                            Justify::FlexStart,
                            Wrap::NoWrap,
                            0.0,
                            AnyView::new(TupleView::new(Vec::new())),
                        )
                        .frame(
                            None,
                            Some(FrameDimension::Points(1.0)),
                            None,
                            None,
                            None,
                            None,
                        )
                        .semantic_background(SemanticColorRef::border()),
                    ),
                ])),
            ),
        )
    }
}

impl View for ShortcutSettings {
    fn body(&self, _scope: &Scope) -> AnyView {
        let rows = self.entries.iter().map(Self::row).collect::<Vec<AnyView>>();
        AnyView::new(SettingsCard::new(
            localized("Keyboard Shortcuts"),
            localized("These shortcuts follow the commands available in the current Space."),
            BoxView::new(
                FlexDirection::Column,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                0.0,
                AnyView::new(TupleView::new(rows)),
            )
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                None,
                None,
                None,
            )
            .debug_name("shortcut-settings"),
        ))
    }
}
