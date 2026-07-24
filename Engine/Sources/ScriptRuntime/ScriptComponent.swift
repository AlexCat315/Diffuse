import SceneRuntime

public struct ScriptHandle: Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct ScriptBinding: Sendable, Equatable {
    public var script: ScriptHandle
    /// Stable project-facing identifier. Numeric handles are process-local and are
    /// retained only for source compatibility with programmatically registered scripts.
    public var identifier: String?
    public var isEnabled: Bool
    public var parametersJSON: String

    public init(_ script: ScriptHandle,
                identifier: String? = nil,
                isEnabled: Bool = true,
                parametersJSON: String = "{}") {
        self.script = script
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.parametersJSON = parametersJSON
    }

    public init(identifier: String,
                isEnabled: Bool = true,
                parametersJSON: String = "{}") {
        self.init(ScriptHandle(rawValue: 0),
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
