import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

enum DeveloperTraceMode: String, Equatable {
    case live = "Live"
    case paused = "Paused"
    case captured = "Captured"
}

enum DeveloperTraceTrack: String, Equatable, Hashable, CaseIterable {
    case frame = "Frame"
    case cpu = "CPU"
    case gpuPresent = "GPU/Present"
    case renderPass = "Render Passes"
    case particles = "Particles"
    case console = "Console"
}

enum DeveloperTraceSeverityFilter: String, Equatable, CaseIterable {
    case all = "All"
    case problems = "Problems"
    case critical = "Errors"
    case warning = "Warnings"
}

enum DeveloperTraceEventSortOrder: String, Equatable, CaseIterable {
    case newest = "Newest"
    case severity = "Severity"
    case track = "Track"
}

enum DeveloperTraceNavigationDirection {
    case previous
    case next
}

struct DeveloperTraceSample: Equatable {
    var sampleIndex: UInt64
    var frameIndex: UInt64
    var frameStats: EditorFrameStats
    var particleLiveCount: Int
    var particleDroppedCount: Int
    var consoleSeverity: DeveloperDiagnosticSeverity?
    var issueIDs: [String]
}

struct DeveloperTraceEvent: Equatable {
    var id: String
    var track: DeveloperTraceTrack
    var sampleIndex: UInt64
    var severity: DeveloperDiagnosticSeverity
    var scope: DeveloperDiagnosticScope
    var title: String
    var primarySignal: String
    var evidence: [String]
    var recommendation: String
    var target: DeveloperDiagnosticTarget
}

struct DeveloperTraceSnapshot: Equatable {
    var mode: DeveloperTraceMode
    var samples: [DeveloperTraceSample]
    var events: [DeveloperTraceEvent]
    var renderPasses: [DeveloperRenderPassInspection]
    var issues: [DeveloperDiagnosticIssue]

    func withMode(_ nextMode: DeveloperTraceMode) -> DeveloperTraceSnapshot {
        var copy = self
        copy.mode = nextMode
        return copy
    }
}

struct DeveloperTraceInvestigationSummary: Equatable {
    var visibleEventCount: Int
    var criticalCount: Int
    var warningCount: Int
    var hotSampleIndex: UInt64?
    var hotSampleEventCount: Int
    var focusEventID: String?
}

struct DeveloperTraceSampleInvestigation: Equatable {
    var sampleIndex: UInt64
    var leadEventID: String?
    var eventCount: Int
    var criticalCount: Int
    var warningCount: Int
    var tracks: [DeveloperTraceTrack]
    var drilldownTargets: [DeveloperDiagnosticTarget]
}

enum DeveloperTraceSampleContextPosition: String, Equatable {
    case previous = "Previous"
    case selected = "Selected"
    case next = "Next"
}

struct DeveloperTraceSampleContextRow: Equatable {
    var position: DeveloperTraceSampleContextPosition
    var sampleIndex: UInt64
    var workMs: Double
    var workDeltaFromSelectedMs: Double
    var eventCount: Int
    var highestSeverity: DeveloperDiagnosticSeverity
}

struct DeveloperTraceSampleContext: Equatable {
    var previous: DeveloperTraceSampleContextRow?
    var selected: DeveloperTraceSampleContextRow
    var next: DeveloperTraceSampleContextRow?
}
