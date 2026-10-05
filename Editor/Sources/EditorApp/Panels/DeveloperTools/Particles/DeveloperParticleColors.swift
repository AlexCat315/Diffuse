import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

func particleSeverityForeground(_ severity: DeveloperParticleDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .idle:
        return .onSurfaceMuted
    case .nominal:
        return .success
    case .info:
        return .info
    case .warning:
        return .warning
    case .critical:
        return .error
    }
}

func particleSeverityBackground(_ severity: DeveloperParticleDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .idle:
        return .surface
    case .nominal:
        return .success.opacity(0.12)
    case .info:
        return .info.opacity(0.12)
    case .warning:
        return .warning.opacity(0.12)
    case .critical:
        return .error.opacity(0.12)
    }
}
