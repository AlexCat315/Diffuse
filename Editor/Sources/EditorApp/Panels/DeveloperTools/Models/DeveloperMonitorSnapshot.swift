import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperMonitorSnapshot: Equatable {
    var track: DeveloperTraceTrack
    var title: String
    var currentValue: Float?
    var currentLabel: String
    var rangeLabel: String
    var sampleLabel: String
    var limit: Float?
    var isOverLimit: Bool
    var values: [Float]
}

func makeDeveloperDiagnosticCounts(_ issues: [DeveloperDiagnosticIssue]) -> DeveloperDiagnosticCounts {
    DeveloperDiagnosticCounts(
        critical: issues.filter { $0.severity == .critical }.count,
        warning: issues.filter { $0.severity == .warning }.count,
        info: issues.filter { $0.severity == .info }.count,
        nominal: issues.filter { $0.severity == .nominal }.count
    )
}
