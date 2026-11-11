//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Particles/DeveloperParticleColors.swift.

use cove_ui_compose::theme::SemanticColorRef;
use diffuse_editor_core::diagnostics::particles::signals::DeveloperParticleDiagnosticSeverity;

pub fn particle_severity_foreground(
    severity: DeveloperParticleDiagnosticSeverity,
) -> SemanticColorRef {
    match severity {
        DeveloperParticleDiagnosticSeverity::Idle => SemanticColorRef::on_surface_muted(),
        DeveloperParticleDiagnosticSeverity::Nominal => SemanticColorRef::success(),
        DeveloperParticleDiagnosticSeverity::Info => SemanticColorRef::info(),
        DeveloperParticleDiagnosticSeverity::Warning => SemanticColorRef::warning(),
        DeveloperParticleDiagnosticSeverity::Critical => SemanticColorRef::error(),
    }
}

pub fn particle_severity_background(
    severity: DeveloperParticleDiagnosticSeverity,
) -> SemanticColorRef {
    match severity {
        DeveloperParticleDiagnosticSeverity::Idle => SemanticColorRef::surface(),
        DeveloperParticleDiagnosticSeverity::Nominal => SemanticColorRef::success().opacity(0.12),
        DeveloperParticleDiagnosticSeverity::Info => SemanticColorRef::info().opacity(0.12),
        DeveloperParticleDiagnosticSeverity::Warning => SemanticColorRef::warning().opacity(0.12),
        DeveloperParticleDiagnosticSeverity::Critical => SemanticColorRef::error().opacity(0.12),
    }
}
