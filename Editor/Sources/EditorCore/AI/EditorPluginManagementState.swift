import Foundation
import PluginRuntime

public enum EditorPluginManagementPhase: String, Codable, Sendable, Equatable {
    case idle
    case inspecting
    case awaitingAuthorization
    case enabling
    case failed
}

public struct EditorPluginCapabilitySummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var access: String
    public var schemaHash: String

    public init(id: String,
                title: String,
                description: String,
                access: String,
                schemaHash: String) {
        self.id = id
        self.title = title
        self.description = description
        self.access = access
        self.schemaHash = schemaHash
    }
}

/// Plain-text, bounded data safe for presentation in the Settings panel.
/// The package URL and executable binding remain private to
/// `EditorApplication`, so mutating observable state cannot enable a plugin.
public struct EditorPluginInspectionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var version: Int
    public var name: String
    public var description: String
    public var access: String
    public var imports: [String]
    public var composableHostCapabilities: [String]
    public var capabilities: [EditorPluginCapabilitySummary]
    public var componentHash: String
    public var witHash: String
    public var hasReusableAuthorization: Bool

    public init(inspection: PluginInspection,
                hasReusableAuthorization: Bool) {
        let manifest = inspection.manifest
        id = manifest.id
        version = manifest.version
        name = manifest.name
        description = manifest.description
        access = manifest.access.rawValue
        imports = manifest.imports.map(\.rawValue).sorted()
        composableHostCapabilities = manifest.composableHostCapabilities.sorted()
        capabilities = inspection.contracts.map {
            EditorPluginCapabilitySummary(id: $0.id,
                                          title: $0.title,
                                          description: $0.description,
                                          access: $0.access.rawValue,
                                          schemaHash: $0.schemaHash)
        }.sorted { $0.id < $1.id }
        componentHash = inspection.componentHash
        witHash = inspection.witHash
        self.hasReusableAuthorization = hasReusableAuthorization
    }
}

public struct EditorPluginManagementState: Codable, Sendable, Equatable {
    public var phase: EditorPluginManagementPhase
    public var candidate: EditorPluginInspectionSummary?
    public var enabled: [EditorPluginInspectionSummary]
    public var message: String?

    public init(phase: EditorPluginManagementPhase = .idle,
                candidate: EditorPluginInspectionSummary? = nil,
                enabled: [EditorPluginInspectionSummary] = [],
                message: String? = nil) {
        self.phase = phase
        self.candidate = candidate
        self.enabled = enabled.sorted { $0.id < $1.id }
        self.message = message
    }

    public static let idle = EditorPluginManagementState()
}
