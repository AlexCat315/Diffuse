//! Desktop workbench composition from RootView.swift.

use std::rc::Rc;

use cove_ui_addons::workspace::WorkspaceView;
use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::primitives::overlays::{LayerRoot, PortalHost, ShortcutHost};
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::{SemanticColorRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, BoxView, Scope, TupleView, View};
use diffuse_editor_core::state::editor_state::EditorThemeMode;

use super::chrome::editor_presentation_boundary::EditorPresentationBoundary;
use super::chrome::shortcut_handler::EditorShortcutHandler;
use super::chrome::unsaved_changes_dialog::UnsavedChangesDialog;
use crate::ai::agent_review::AgentReview;
use crate::commands::catalog::{EditorCommandCatalog, EditorCommandContext};
use crate::commands::dispatcher::EditorCommandDispatcher;
use crate::projects::editor_launch_context::{EditorLaunchBundle, EditorLaunchContext};
use crate::shell::title_bar::EditorTitleBar;

pub struct EditorRootView {
    context: Rc<EditorLaunchContext>,
    bundle: Rc<EditorLaunchBundle>,
}

impl EditorRootView {
    pub fn new(context: Rc<EditorLaunchContext>, bundle: Rc<EditorLaunchBundle>) -> Self {
        Self { context, bundle }
    }
}

impl View for EditorRootView {
    fn body(&self, _scope: &Scope) -> AnyView {
        let app = &self.bundle.app;
        let presentation = app.store.presentation();
        let theme = app.resolved_theme(presentation.theme_mode == EditorThemeMode::Dark);
        let shortcut = ShortcutHost::new({
            let bundle = self.bundle.clone();
            let context = self.context.clone();
            move |key| {
                let model = EditorCommandContext::from_application(&bundle.app);
                let catalog = EditorCommandCatalog::make(&model);
                if !catalog.entry(key).is_some_and(|entry| EditorCommandDispatcher::is_wired(&entry.command)) {
                    return false;
                }
                EditorShortcutHandler::handle_default(key, &catalog, false, &mut || {}, &mut |command| {
                    EditorCommandDispatcher::handle(command, &bundle, &context);
                })
            }
        });
        let workspace = WorkspaceView::with_registry(self.bundle.controller.clone(), &self.bundle.registry)
            .flex(1.0).padding_edges(6.0, 0.0);
        let content = BoxView::new(FlexDirection::Column, Align::Stretch, Justify::FlexStart, Wrap::NoWrap, 0.0,
            AnyView::new(TupleView::new(vec![
                AnyView::new(shortcut),
                AnyView::new(EditorTitleBar::new(self.context.clone(), self.bundle.clone())),
                AnyView::new(workspace),
            ]))).semantic_background(SemanticColorRef::background()).flex(1.0);
        let mut portals = vec![AnyView::new(PortalHost::new())];
        if let Some(request) = app.store.pending_close_request() {
            portals.push(AnyView::new(UnsavedChangesDialog::new(app.clone(), request)));
        } else if let Some(request) = app.store.pending_confirmation_request() {
            portals.push(AnyView::new(AgentReview::new(app.clone(), request)));
        }
        AnyView::new(EditorPresentationBoundary::new(
            presentation, Some(theme),
            AnyView::new(LayerRoot::with_portals(content, TupleView::new(portals))),
        ))
    }
}
