//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Shared/DeveloperDiagnosticColors.swift.

use cove_ui_compose::theme::SemanticColorRef;
use diffuse_editor_core::diagnostics::issues::diagnostic_issue::DeveloperDiagnosticSeverity;

pub fn developer_diagnostic_foreground(severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    match severity {
        DeveloperDiagnosticSeverity::Nominal => SemanticColorRef::success(),
        DeveloperDiagnosticSeverity::Info => SemanticColorRef::info(),
        DeveloperDiagnosticSeverity::Warning => SemanticColorRef::warning(),
        DeveloperDiagnosticSeverity::Critical => SemanticColorRef::error(),
    }
}

pub fn developer_diagnostic_background(severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    base_ref(severity).opacity(0.12)
}

pub fn developer_diagnostic_border(severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    let opacity = match severity {
        DeveloperDiagnosticSeverity::Nominal | DeveloperDiagnosticSeverity::Info => 0.25,
        DeveloperDiagnosticSeverity::Warning => 0.35,
        DeveloperDiagnosticSeverity::Critical => 0.40,
    };
    base_ref(severity).opacity(opacity)
}

pub fn render_pass_encode_color(encode_ns: u64) -> SemanticColorRef {
    if encode_ns > 16_700_000 {
        return SemanticColorRef::error();
    }
    if encode_ns > 8_000_000 {
        return SemanticColorRef::warning();
    }
    if encode_ns > 0 {
        return SemanticColorRef::on_surface();
    }
    SemanticColorRef::on_surface_muted()
}

pub fn render_pass_encode_border(encode_ns: u64) -> SemanticColorRef {
    if encode_ns > 16_700_000 {
        return SemanticColorRef::error().opacity(0.40);
    }
    if encode_ns > 8_000_000 {
        return SemanticColorRef::warning().opacity(0.35);
    }
    SemanticColorRef::border()
}

fn base_ref(severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    match severity {
        DeveloperDiagnosticSeverity::Nominal => SemanticColorRef::success(),
        DeveloperDiagnosticSeverity::Info => SemanticColorRef::info(),
        DeveloperDiagnosticSeverity::Warning => SemanticColorRef::warning(),
        DeveloperDiagnosticSeverity::Critical => SemanticColorRef::error(),
    }
}
