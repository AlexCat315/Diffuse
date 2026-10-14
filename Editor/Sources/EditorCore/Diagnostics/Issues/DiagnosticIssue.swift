public enum DeveloperDiagnosticArea: String, Codable, Sendable {
    case frame, render, particles, console, state
}

import Foundation
import RenderBackend
import SceneRuntime

public enum DeveloperDiagnosticSeverity: String, Codable, Sendable, Equatable {
    case nominal = "Nominal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"
}

public enum DeveloperDiagnosticScope: String, Codable, Sendable, Equatable {
    case frame = "Frame"
    case render = "Render"
    case particles = "Particles"
    case console = "Console"
    case state = "State"
}

public struct DeveloperDiagnosticTarget: Codable, Sendable, Equatable {
    public let area: DeveloperDiagnosticArea
    public let frameSampleIndex: UInt64?
    public let label: String
    public init(area: DeveloperDiagnosticArea, frameSampleIndex: UInt64?, label: String) {
        self.area = area; self.frameSampleIndex = frameSampleIndex; self.label = label
    }
}

public struct DeveloperDiagnosticIssue: Codable, Sendable, Equatable {
    public let id: String
    public let severity: DeveloperDiagnosticSeverity
    public let scope: DeveloperDiagnosticScope
    public let title: String
    public let primarySignal: String
    public let evidence: [String]
    public let recommendation: String
    public let target: DeveloperDiagnosticTarget
}

public struct DeveloperDiagnosticCounts: Codable, Sendable, Equatable {
    public let critical: Int
    public let warning: Int
    public let info: Int
    public let nominal: Int
    public init(critical: Int, warning: Int, info: Int, nominal: Int) {
        self.critical = critical; self.warning = warning; self.info = info; self.nominal = nominal
    }
}
