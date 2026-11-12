//! Translation of
//! Editor/Sources/EditorUI/Root/Chrome/EditorPresentationBoundary.swift.

use cove_ui_compose::theme::tokens::{ControlSize, ControlSizeViewExt};
use cove_ui_compose::theme::{Theme, ThemeViewExt};
use cove_ui_compose::{AnyView, Scope, View, ViewExt};
use diffuse_editor_core::state::editor_presentation_state::EditorPresentationState;
use diffuse_editor_core::state::editor_state::EditorThemeMode;

use crate::root::chrome::editor_visual_theme::EditorVisualTheme;

/// Applies the editor's presentation tokens to everything below it.
///
/// `refresh_revision` is the only thing that rebuilds the subtree: a theme or
/// language change arrives through `ThemeEnvironment` instead, which repaints
/// the layers that resolve a token without remounting or re-measuring them.
pub struct EditorPresentationBoundary<Content: View + Clone + 'static> {
    pub presentation: EditorPresentationState,
    pub content: Content,
    pub theme: Option<Theme>,
}

impl<Content: View + Clone + 'static> EditorPresentationBoundary<Content> {
    pub fn new(
        presentation: EditorPresentationState,
        theme: Option<Theme>,
        content: Content,
    ) -> Self {
        EditorPresentationBoundary {
            presentation,
            content,
            theme,
        }
    }
}

impl<Content: View + Clone + 'static> View for EditorPresentationBoundary<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        let theme = self.theme.clone().unwrap_or_else(|| {
            EditorVisualTheme::make_with_theme_id(
                self.presentation.theme_mode == EditorThemeMode::Dark,
                &self.presentation.theme_id,
            )
        });
        AnyView::new(
            self.content
                .clone()
                .id(self.presentation.refresh_revision)
                .theme(theme)
                .control_size(ControlSize::Small),
        )
    }
}
