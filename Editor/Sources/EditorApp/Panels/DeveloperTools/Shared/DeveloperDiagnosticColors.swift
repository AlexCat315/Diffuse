import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

func developerDiagnosticForeground(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
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

func developerDiagnosticBackground(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
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

func developerDiagnosticBorder(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .nominal:
        return .success.opacity(0.25)
    case .info:
        return .info.opacity(0.25)
    case .warning:
        return .warning.opacity(0.35)
    case .critical:
        return .error.opacity(0.40)
    }
}

func renderPassEncodeColor(_ encodeNS: UInt64) -> SemanticColorRef {
    if encodeNS > 16_700_000 { return .error }
    if encodeNS > 8_000_000 { return .warning }
    if encodeNS > 0 { return .onSurface }
    return .onSurfaceMuted
}

func renderPassEncodeBorder(_ encodeNS: UInt64) -> SemanticColorRef {
    if encodeNS > 16_700_000 { return .error.opacity(0.40) }
    if encodeNS > 8_000_000 { return .warning.opacity(0.35) }
    return .border
}
