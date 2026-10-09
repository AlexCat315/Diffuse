import Foundation
import SceneRuntime

/// Stable identity for one attachment of a script to an entity.
///
/// The script identifier names the behavior, while the binding identifier names
/// the individual attachment. Keeping the latter stable prevents two bindings
/// of the same script from exchanging state when they are reordered or one is
/// disabled.
public struct ScriptBindingID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    public var uuidString: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid script binding UUID '\(value)'."
            )
        }
        rawValue = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuidString)
    }
}

public struct ScriptHandle: Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct ScriptBinding: Sendable, Equatable {
    public var id: ScriptBindingID
    public var script: ScriptHandle
    /// Stable project-facing identifier. Numeric handles are process-local and are
    /// retained only for source compatibility with programmatically registered scripts.
    public var identifier: String?
    public var isEnabled: Bool
    public var parametersJSON: String

    public init(_ script: ScriptHandle,
                id: ScriptBindingID = ScriptBindingID(),
                identifier: String? = nil,
                isEnabled: Bool = true,
                parametersJSON: String = "{}") {
        self.id = id
        self.script = script
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.parametersJSON = parametersJSON
    }

    public init(identifier: String,
                id: ScriptBindingID = ScriptBindingID(),
                isEnabled: Bool = true,
                parametersJSON: String = "{}") {
        self.init(ScriptHandle(rawValue: 0),
                  id: id,
                  identifier: identifier,
                  isEnabled: isEnabled,
                  parametersJSON: parametersJSON)
    }
}

public struct ScriptComponent: RuntimeComponent, Sendable, Equatable {
    public var bindings: [ScriptBinding]

    public init(bindings: [ScriptBinding] = []) {
        self.bindings = bindings
    }

    public init(_ bindings: ScriptBinding...) {
        self.bindings = bindings
    }

    public init(_ scripts: ScriptHandle...) {
        self.bindings = scripts.map { ScriptBinding($0) }
    }
}
