//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Debugger/DeveloperIssueQueue.swift.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, PlainButtonStyle};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, Column, HorizontalAlignment, Row, Scope, TupleView, VerticalAlignment, View,
};
use diffuse_editor_core::diagnostics::issues::diagnostic_issue::{
    DeveloperDiagnosticIssue, DeveloperDiagnosticSeverity, DeveloperDiagnosticTarget,
};

use super::super::shared::developer_diagnostic_colors::{
    developer_diagnostic_background, developer_diagnostic_border, developer_diagnostic_foreground,
};

pub type OpenTargetHandler = Rc<dyn Fn(&DeveloperDiagnosticTarget)>;

pub struct DeveloperIssueQueueView {
    pub issues: Vec<DeveloperDiagnosticIssue>,
    pub title: String,
    pub on_open_target: OpenTargetHandler,
}

impl DeveloperIssueQueueView {
    pub fn new(
        issues: Vec<DeveloperDiagnosticIssue>,
        title: impl Into<String>,
        on_open_target: OpenTargetHandler,
    ) -> Self {
        DeveloperIssueQueueView {
            issues,
            title: title.into(),
            on_open_target,
        }
    }
}

impl View for DeveloperIssueQueueView {
    fn body(&self, _scope: &Scope) -> AnyView {
        let header = AnyView::new(
            Text::new(self.title.clone())
                .semantic_font(SemanticFontRef::body_strong())
                .semantic_foreground(SemanticColorRef::on_surface())
                .padding_edges(10.0, 8.0),
        );
        let rows: Vec<AnyView> = self
            .issues
            .iter()
            .map(|issue| {
                AnyView::new(DeveloperIssueRowView {
                    issue: issue.clone(),
                    on_open_target: self.on_open_target.clone(),
                })
            })
            .collect();
        let list = AnyView::new(
            Column::new(
                HorizontalAlignment::Leading,
                6.0,
                AnyView::new(TupleView::new(rows)),
            )
            .padding_edges(8.0, 0.0),
        );
        AnyView::new(Column::new(
            HorizontalAlignment::Leading,
            6.0,
            AnyView::new(TupleView::new(vec![header, list])),
        ))
    }
}

struct DeveloperIssueRowView {
    issue: DeveloperDiagnosticIssue,
    on_open_target: OpenTargetHandler,
}

impl View for DeveloperIssueRowView {
    fn body(&self, _scope: &Scope) -> AnyView {
        let issue = &self.issue;
        let handler = self.on_open_target.clone();
        let target = issue.target.clone();
        let badge_text = issue.severity.raw_value().to_string();

        let header = AnyView::new(Row::new(
            VerticalAlignment::Center,
            8.0,
            AnyView::new(TupleView::new(vec![
                AnyView::new(DeveloperSeverityBadgeView {
                    severity: issue.severity,
                    text: badge_text,
                }),
                AnyView::new(
                    Text::new(issue.scope.raw_value())
                        .semantic_font(SemanticFontRef::caption())
                        .semantic_foreground(SemanticColorRef::on_surface_muted()),
                ),
                AnyView::new(
                    Text::new(issue.title.clone())
                        .line_limit(Some(1))
                        .semantic_font(SemanticFontRef::body_strong())
                        .semantic_foreground(SemanticColorRef::on_surface())
                        .flex_with(1.0, 1.0, None),
                ),
                AnyView::new(
                    Text::new(issue.target.label.clone())
                        .semantic_font(SemanticFontRef::caption())
                        .semantic_foreground(SemanticColorRef::accent()),
                ),
            ])),
        ));

        let signal = AnyView::new(
            Text::new(issue.primary_signal.clone())
                .line_limit(Some(2))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface()),
        );

        let mut body_views: Vec<AnyView> = vec![header, signal];
        if !issue.evidence.is_empty() {
            let evidence = issue
                .evidence
                .iter()
                .take(3)
                .cloned()
                .collect::<Vec<_>>()
                .join(" | ");
            body_views.push(AnyView::new(
                Text::new(evidence)
                    .line_limit(Some(2))
                    .semantic_font(SemanticFontRef::caption())
                    .semantic_foreground(SemanticColorRef::on_surface_muted()),
            ));
        }
        body_views.push(AnyView::new(
            Text::new(issue.recommendation.clone())
                .line_limit(Some(2))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_muted()),
        ));

        let card = AnyView::new(
            AnyView::new(Column::new(
                HorizontalAlignment::Leading,
                5.0,
                AnyView::new(TupleView::new(body_views)),
            ))
            .padding_edges(10.0, 8.0)
            .semantic_background(SemanticColorRef::surface_sunken())
            .corner_radius(6.0)
            .semantic_border(developer_diagnostic_border(issue.severity), 1.0),
        );

        AnyView::new(
            Button::new(card, move || {
                handler(&target);
            })
            .button_style(PlainButtonStyle),
        )
    }
}

struct DeveloperSeverityBadgeView {
    severity: DeveloperDiagnosticSeverity,
    text: String,
}

impl View for DeveloperSeverityBadgeView {
    fn body(&self, _scope: &Scope) -> AnyView {
        AnyView::new(
            Text::new(self.text.clone())
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(developer_diagnostic_foreground(self.severity))
                .padding_edges(7.0, 2.0)
                .semantic_background(developer_diagnostic_background(self.severity))
                .corner_radius(4.0),
        )
    }
}
