import Foundation
import ScriptRuntime

public enum ProjectScriptCatalogError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported project script catalog schema version: \(version)"
        }
    }
}

public indirect enum ProjectScriptJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ProjectScriptJSONValue])
    case object([String: ProjectScriptJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ProjectScriptJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ProjectScriptJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public struct ProjectScriptDefinition: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var preset: String
    public var defaultParameters: [String: ProjectScriptJSONValue]

    public init(id: String,
                displayName: String? = nil,
                preset: String,
                defaultParameters: [String: ProjectScriptJSONValue] = [:]) {
        self.id = id
        self.displayName = displayName
        self.preset = preset
        self.defaultParameters = defaultParameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, preset, defaultParameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        preset = try container.decode(String.self, forKey: .preset)
        defaultParameters = try container.decodeIfPresent(
            [String: ProjectScriptJSONValue].self,
            forKey: .defaultParameters
        ) ?? [:]
    }
}

public struct ProjectScriptManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var scripts: [ProjectScriptDefinition]

    public init(schemaVersion: Int = 1, scripts: [ProjectScriptDefinition] = []) {
        self.schemaVersion = schemaVersion
        self.scripts = scripts
    }
}

public struct ProjectScriptCatalogEntry: Sendable, Equatable {
    public var identifier: String
    public var displayName: String
    public var preset: ScriptPresetKind
    public var defaultParametersJSON: String
    public var isBuiltIn: Bool
}

public struct ProjectScriptCatalogDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public var severity: Severity
    public var message: String
}

public struct ProjectScriptCatalog: Sendable, Equatable {
    public var entries: [ProjectScriptCatalogEntry]
    public var diagnostics: [ProjectScriptCatalogDiagnostic]
    public var sourceURL: URL?

    public static let relativePath = "Scripts/scripts.json"

    public static var builtIn: ProjectScriptCatalog {
        ProjectScriptCatalog(entries: builtInEntries, diagnostics: [], sourceURL: nil)
    }

    public static func load(projectDirectory: String) throws -> ProjectScriptCatalog {
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let url = root.appendingPathComponent(relativePath)
        var entries = builtInEntries
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProjectScriptCatalog(entries: entries, diagnostics: [], sourceURL: nil)
        }

        let manifest = try JSONDecoder().decode(ProjectScriptManifest.self,
                                                from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1 else {
            throw ProjectScriptCatalogError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        var diagnostics: [ProjectScriptCatalogDiagnostic] = []
        var identifiers = Set(entries.map(\.identifier))
        for definition in manifest.scripts {
            let identifier = definition.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIdentifier(identifier) else {
                diagnostics.append(.init(
                    severity: .error,
                    message: "Invalid script id '\(definition.id)'; use letters, numbers, '.', '_' or '-'."
                ))
                continue
            }
            guard identifiers.insert(identifier).inserted else {
                diagnostics.append(.init(severity: .error,
                                         message: "Duplicate script id '\(identifier)'."))
                continue
            }
            guard let preset = ScriptPresetKind(rawValue: definition.preset) else {
                diagnostics.append(.init(
                    severity: .error,
                    message: "Script '\(identifier)' uses unknown preset '\(definition.preset)'."
                ))
                continue
            }
            let parameters = try encodeParameters(definition.defaultParameters)
            let name = definition.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(ProjectScriptCatalogEntry(
                identifier: identifier,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? identifier,
                preset: preset,
                defaultParametersJSON: parameters,
                isBuiltIn: false
            ))
        }
        return ProjectScriptCatalog(entries: entries,
                                    diagnostics: diagnostics,
                                    sourceURL: url)
    }

    private static func encodeParameters(
        _ parameters: [String: ProjectScriptJSONValue]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(parameters), as: UTF8.self)
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let builtInEntries: [ProjectScriptCatalogEntry] = [
        .init(identifier: "guava.rotator", displayName: "Rotator", preset: .rotator,
              defaultParametersJSON: #"{"speed":[0,1.57,0]}"#, isBuiltIn: true),
        .init(identifier: "guava.oscillator", displayName: "Oscillator", preset: .oscillator,
              defaultParametersJSON: #"{"axis":[0,1,0],"amplitude":1,"frequency":1}"#,
              isBuiltIn: true),
        .init(identifier: "guava.mover", displayName: "Mover", preset: .mover,
              defaultParametersJSON: #"{"velocity":[0,0,0]}"#, isBuiltIn: true),
        .init(identifier: "guava.destroy-after", displayName: "Destroy After",
              preset: .destroyAfter, defaultParametersJSON: #"{"seconds":1}"#, isBuiltIn: true),
        .init(identifier: "guava.follower", displayName: "Follower", preset: .follower,
              defaultParametersJSON: #"{"targetEntityName":"","speed":5,"arrivalRadius":0.1}"#,
              isBuiltIn: true),
        .init(identifier: "guava.look-at", displayName: "Look At", preset: .lookAt,
              defaultParametersJSON: #"{"targetEntityName":""}"#, isBuiltIn: true),
        .init(identifier: "guava.character-controller", displayName: "Character Controller Input",
              preset: .characterController,
              defaultParametersJSON: #"{"moveSpeed":5,"jumpSpeed":8,"crouchAction":"crouch"}"#,
              isBuiltIn: true),
        .init(identifier: "guava.first-person-camera", displayName: "First Person Camera",
              preset: .firstPersonCamera,
              defaultParametersJSON: #"{"moveSpeed":5,"lookSensitivity":0.002}"#,
              isBuiltIn: true),
        .init(identifier: "guava.orbit-camera", displayName: "Orbit Camera", preset: .orbitCamera,
              defaultParametersJSON: #"{"target":[0,0,0],"distance":10,"orbitSpeed":0.005,"zoomSpeed":1,"minDistance":1,"maxDistance":100}"#,
              isBuiltIn: true),
    ]
}

/// Cheap file-signature monitor shared by Editor and standalone Player.
public final class ProjectScriptCatalogMonitor: @unchecked Sendable {
    private struct Signature: Equatable {
        var exists: Bool
        var modifiedAt: Date?
        var fileSize: Int?
        var contents: Data?
    }

    private let projectDirectory: String
    private var lastSignature: Signature?

    public init(projectDirectory: String) {
        self.projectDirectory = projectDirectory
    }

    public func loadIfChanged(force: Bool = false) throws -> ProjectScriptCatalog? {
        let url = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(ProjectScriptCatalog.relativePath)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let signature = Signature(exists: FileManager.default.fileExists(atPath: url.path),
                                  modifiedAt: values?.contentModificationDate,
                                  fileSize: values?.fileSize,
                                  contents: try? Data(contentsOf: url))
        guard force || signature != lastSignature else { return nil }
        lastSignature = signature
        return try ProjectScriptCatalog.load(projectDirectory: projectDirectory)
    }
}
