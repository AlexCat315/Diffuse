//! `Editor/Sources/EditorUI/Root/EditorLaunchRoot.swift`.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::overlays::LayerRoot;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::styles::buttons::ButtonStyleViewExt;
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt, ThemeViewExt};
use cove_ui_compose::{
    AnyView, BoxView, DynamicField, Observed, Row, Scope, TupleView, VerticalAlignment, View, ViewExt,
};
use diffuse_editor_core::state::editor_state::EditorThemeMode;

use super::chrome::editor_visual_theme::EditorVisualTheme;
use super::chrome::settings_window_root::EditorSettingsWindowRoot;
use super::root_view::EditorRootView;
use crate::localization::localized;
use crate::projects::editor_launch_context::EditorLaunchContext;
use crate::shell::appearance::EditorChromeButtonStyle;

pub struct EditorLaunchRoot {
    context: Rc<EditorLaunchContext>,
    state: Observed<EditorLaunchContext, (Option<String>, Option<String>)>,
    settings_requested: bool,
}

impl EditorLaunchRoot {
    pub fn new(context: Rc<EditorLaunchContext>, settings_requested: bool) -> Self {
        let state = Observed::new(context.clone(), |context| {
            (context.active_directory(), context.open_failure())
        });
        Self { context, state, settings_requested }
    }
}

impl View for EditorLaunchRoot {
    fn body(&self, _scope: &Scope) -> AnyView {
        let (active, failure) = self.state.get();
        if let Some(active) = active
            && let Some(bundle) = self.context.bundle_for(&active)
        {
            return if self.settings_requested {
                AnyView::new(EditorSettingsWindowRoot(bundle.app.clone()).id(active))
            } else {
                AnyView::new(EditorRootView::new(self.context.clone(), bundle).id(active))
            };
        }
        let mut body = vec![AnyView::new(
            Text::new(localized("The workspace could not be opened")).semantic_font(SemanticFontRef::body_strong()),
        )];
        if let Some(failure) = failure {
            body.push(AnyView::new(Text::new(failure)
                .semantic_font(SemanticFontRef::caption()).semantic_foreground(SemanticColorRef::error())));
        }
        let buttons = vec![
            AnyView::new(Button::title(localized("Untitled Workspace"), {
                let context = self.context.clone();
                move || { context.open_scratch_workspace(); }
            }).button_style(EditorChromeButtonStyle { height: 30.0, agent: true })),
            AnyView::new(Button::title(localized("Open Folder..."), {
                let context = self.context.clone();
                move || context.request_open_folder()
            }).button_style(EditorChromeButtonStyle::new(30.0))),
        ];
        body.push(AnyView::new(Row::new(
            VerticalAlignment::Center, 6.0, AnyView::new(TupleView::new(buttons)),
        )));
        let inner = BoxView::new(
            FlexDirection::Column, Align::Center, Justify::Center, Wrap::NoWrap,
            10.0, AnyView::new(TupleView::new(body)),
        ).padding(24.0).semantic_background(SemanticColorRef::background()).flex(1.0);
        let preferences = self.context.shell_state();
        let theme = match preferences {
            Some(state) => EditorVisualTheme::make_with_theme_id(state.theme_mode != EditorThemeMode::Light, &state.theme_id),
            None => EditorVisualTheme::make(true),
        };
        AnyView::new(LayerRoot::new(inner).theme(theme))
    }

    fn dynamic_properties(&self) -> Vec<DynamicField> {
        vec![self.state.dynamic_field("project")]
    }
}
