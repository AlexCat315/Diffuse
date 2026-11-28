//! Local confirmation of proposed scene edits from AgentReview.swift.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::layout::ScrollView;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, primary, secondary};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, Column, HorizontalAlignment, Row, Scope, Spacer, TupleView, VerticalAlignment, View};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_intent::invocation::capability_invocation::{ConfirmationRequestBatch, ConfirmationSeverity};

use crate::localization::localized;
use crate::root::chrome::modal_barrier::ModalBarrier;

pub struct AgentReview {
    app: Rc<EditorApplication>,
    request: ConfirmationRequestBatch,
}

impl AgentReview {
    pub fn new(app: Rc<EditorApplication>, request: ConfirmationRequestBatch) -> Self { Self { app, request } }
}

impl View for AgentReview {
    fn body(&self, _scope: &Scope) -> AnyView {
        let mut questions = Vec::new();
        for question in &self.request.questions {
            let tone = if question.severity == ConfirmationSeverity::Destructive {
                SemanticColorRef::error()
            } else {
                SemanticColorRef::on_surface()
            };
            questions.push(AnyView::new(Text::new(question.prompt_short.clone()).semantic_foreground(tone)));
            if let Some(detail) = &question.prompt_detail {
                questions.push(AnyView::new(Text::new(detail.clone()).semantic_foreground(SemanticColorRef::on_surface_variant())));
            }
        }
        let controls = Row::new(VerticalAlignment::Center, 8.0, AnyView::new(TupleView::new(vec![
            AnyView::new(Spacer::default()),
            AnyView::new(Button::title(localized("Skip"), { let app = self.app.clone(); move || app.skip_pending_confirmation() }).button_style(secondary())),
            AnyView::new(Button::title(localized("Apply"), { let app = self.app.clone(); move || app.accept_pending_confirmation() }).button_style(primary())),
        ])));
        let body = Column::new(HorizontalAlignment::Leading, 14.0, AnyView::new(TupleView::new(vec![
            AnyView::new(Text::new(localized("Review changes")).semantic_font(SemanticFontRef::headline())),
            AnyView::new(ScrollView::vertical(Column::new(HorizontalAlignment::Leading, 4.0, AnyView::new(TupleView::new(questions))))),
            AnyView::new(controls),
        ]))).padding(24.0).frame_width(640.0).semantic_background(SemanticColorRef::surface_floating()).corner_radius(14.0);
        AnyView::new(ModalBarrier::new(AnyView::new(body)))
    }
}
