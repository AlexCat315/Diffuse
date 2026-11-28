//! `Editor/Sources/EditorUI/Root/Chrome/UnsavedChangesDialog.swift`.

use std::path::Path;
use std::rc::Rc;

use cove_platform::WindowId;
use cove_ui::hosts::desktop::application::composition::AppDisplayHandleHolder;
use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::controls::{Button, ButtonRole};
use cove_ui_compose::primitives::overlays::ShortcutHost;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ghost, primary, secondary};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, Column, HorizontalAlignment, Row, Scancode, Scope, Spacer, TupleView,
    VerticalAlignment, View,
};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::{EditorPendingCloseRequest, EditorPendingDocumentAction};

use super::modal_barrier::ModalBarrier;
use crate::localization::localized;
use crate::projects::editor_launch_context::EditorLaunchContext;

#[derive(Clone)]
pub struct UnsavedChangesDialog {
    app: Rc<EditorApplication>,
    request: EditorPendingCloseRequest,
}

impl UnsavedChangesDialog {
    pub fn new(app: Rc<EditorApplication>, request: EditorPendingCloseRequest) -> Self {
        Self { app, request }
    }

    fn cancel(&self) {
        self.app.store.dispatch(EditorAction::DismissCloseRequest);
    }

    fn save_and_proceed(&self) {
        use EditorPendingDocumentAction::*;
        if matches!(self.request.action, Close | CloseProject) && !self.app.workstation.save_all() {
            return;
        }
        if self.app.save_scene_manifest().is_some() {
            self.proceed();
        }
    }

    fn discard_and_proceed(&self) {
        if self.request.action != EditorPendingDocumentAction::OpenScene {
            self.app.discard_autosaved_scene();
        }
        self.proceed();
    }

    fn proceed(&self) {
        use EditorPendingDocumentAction::*;
        self.cancel();
        match self.request.action {
            NewScene => self.app.create_empty_scene(),
            OpenScene => {
                if let Some(path) = &self.request.document_path {
                    self.app.open_scene_manifest_at(Path::new(path));
                } else {
                    self.app.open_scene_manifest();
                }
            }
            CloseProject => self.app.close_project(),
            Close => {
                let window = self.request.window_id.map(WindowId);
                if let Some(context) = EditorLaunchContext::current() {
                    context.continue_close(window, &self.app);
                } else if let Some(display) = AppDisplayHandleHolder::current() {
                    match window {
                        Some(window) => display.close_window(window),
                        None => display.quit(),
                    }
                }
            }
        }
    }
}

impl View for UnsavedChangesDialog {
    fn body(&self, _scope: &Scope) -> AnyView {
        use EditorPendingDocumentAction::*;
        let (message, discard, save) = match self.request.action {
            Close | CloseProject => (
                "The project has unsaved scene, document or media changes. Save before closing?",
                "Close Without Saving", "Save and Close",
            ),
            NewScene => (
                "The scene has unsaved changes. Save before creating a new scene?",
                "Discard and Create New", "Save and Create New",
            ),
            OpenScene => (
                "The scene has unsaved changes. Save before opening another scene?",
                "Discard and Open", "Save and Open",
            ),
        };
        let key_host = ShortcutHost::new({
            let dialog = self.clone();
            move |key| {
                if !key.is_repeat {
                    match key.scancode {
                        Scancode::ESCAPE => dialog.cancel(),
                        Scancode::RETURN | Scancode::KEYPAD_ENTER => dialog.save_and_proceed(),
                        _ => {}
                    }
                }
                true
            }
        });
        let actions = Row::new(VerticalAlignment::Center, 8.0, AnyView::new(TupleView::new(vec![
            AnyView::new(Button::title(localized(discard), {
                let dialog = self.clone();
                move || dialog.discard_and_proceed()
            }).role(ButtonRole::Destructive).button_style(secondary())),
            AnyView::new(Spacer::default()),
            AnyView::new(Button::title(localized("Cancel"), {
                let dialog = self.clone();
                move || dialog.cancel()
            }).button_style(ghost())),
            AnyView::new(Button::title(localized(save), {
                let dialog = self.clone();
                move || dialog.save_and_proceed()
            }).button_style(primary())),
        ])));
        let content = Column::new(HorizontalAlignment::Leading, 12.0, AnyView::new(TupleView::new(vec![
            AnyView::new(key_host),
            AnyView::new(Text::new(localized("Unsaved Changes")).semantic_font(SemanticFontRef::headline())),
            AnyView::new(Text::new(localized(message)).semantic_foreground(SemanticColorRef::on_surface_variant())),
            AnyView::new(actions),
        ]))).padding(20.0).frame_width(440.0)
            .semantic_background(SemanticColorRef::surface_floating()).corner_radius(14.0);
        AnyView::new(ModalBarrier::new(AnyView::new(content)))
    }
}
