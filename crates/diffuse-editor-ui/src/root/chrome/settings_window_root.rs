//! General editor preferences in the Settings window.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::primitives::controls::fields::select::{Select, SelectOption};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::Binding;
use cove_ui_compose::theme::{SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, Column, HorizontalAlignment, Row, Scope, TupleView, VerticalAlignment, View};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::{EditorLanguage, EditorThemeMode, EditorVSyncMode};

use crate::localization::localized;
use super::editor_presentation_boundary::EditorPresentationBoundary;

pub struct EditorSettingsWindowRoot(pub Rc<EditorApplication>);

impl View for EditorSettingsWindowRoot {
    fn body(&self, _scope: &Scope) -> AnyView {
        let app = &self.0;
        let theme = preference(app, |app| app.store.presentation().theme_mode, EditorAction::SetThemeMode);
        let language = preference(app, |app| app.store.language(), EditorAction::SetLanguage);
        let vsync = preference(app, |app| app.store.vsync_mode(), EditorAction::SetVSyncMode);
        let rows = vec![
            AnyView::new(Text::new(localized("General")).semantic_font(SemanticFontRef::headline())),
            row("Appearance", theme, [(EditorThemeMode::Dark, "Dark"), (EditorThemeMode::Light, "Light")]),
            row("Language", language, [(EditorLanguage::System, "System"), (EditorLanguage::English, "English"), (EditorLanguage::SimplifiedChinese, "Simplified Chinese")]),
            row("VSync", vsync, [(EditorVSyncMode::Enabled, "Enabled"), (EditorVSyncMode::Disabled, "Disabled")]),
        ];
        let view = Column::new(HorizontalAlignment::Leading, 16.0, AnyView::new(TupleView::new(rows))).padding(24.0);
        AnyView::new(EditorPresentationBoundary::new(
            app.store.presentation(),
            Some(app.resolved_theme(app.store.presentation().theme_mode == EditorThemeMode::Dark)),
            AnyView::new(view),
        ))
    }
}

fn preference<T: 'static>(
    app: &Rc<EditorApplication>,
    get: fn(&EditorApplication) -> T,
    set: fn(T) -> EditorAction,
) -> Binding<T> {
    Binding::new(
        { let app = app.clone(); move || get(&app) },
        { let app = app.clone(); move |value| app.store.dispatch(set(value)) },
    )
}

fn row<T: Copy + Eq + Send + Sync + 'static>(
    label: &str,
    selection: Binding<T>,
    options: impl IntoIterator<Item = (T, &'static str)>,
) -> AnyView {
    let options = options.into_iter().map(|(value, name)| SelectOption::new(value, localized(name), true)).collect();
    AnyView::new(Row::new(VerticalAlignment::Center, 14.0, AnyView::new(TupleView::new(vec![
        AnyView::new(Text::new(localized(label)).frame_width(112.0)),
        AnyView::new(Select::new(selection, options).width(216.0)),
    ]))))
}
