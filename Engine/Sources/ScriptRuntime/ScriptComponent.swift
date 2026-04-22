import SceneRuntime

public struct ScriptHandle: Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct ScriptBinding: Sendable, Equatable {
    public var script: ScriptHandle
    public var isEnabled: Bool

    public init(_ script: ScriptHandle, isEnabled: Bool = true) {
        self.script = script
        self.isEnabled = isEnabled
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