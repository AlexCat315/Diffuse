import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

enum DeveloperDiagnosticSeverity: String, Equatable {
    case nominal = "Nominal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"
}

enum DeveloperDiagnosticScope: String, Equatable {
    case frame = "Frame"
    case render = "Render"
    case particles = "Particles"
    case console = "Console"
    case state = "State"
}

struct DeveloperDiagnosticTarget: Equatable {
    var tab: DeveloperToolTab
    var frameSampleIndex: UInt64?
    var label: String
}

struct DeveloperDiagnosticIssue: Equatable {
    var id: String
    var severity: DeveloperDiagnosticSeverity
    var scope: DeveloperDiagnosticScope
    var title: String
    var primarySignal: String
    var evidence: [String]
    var recommendation: String
    var target: DeveloperDiagnosticTarget
}

struct DeveloperDiagnosticCounts: Equatable {
    var critical: Int
    var warning: Int
    var info: Int
    var nominal: Int
}
