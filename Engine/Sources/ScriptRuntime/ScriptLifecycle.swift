public typealias ScriptCallback = @Sendable (ScriptContext) -> Void

public struct Script: Sendable {
    var onStartHandler: ScriptCallback?
    var onTickHandler: ScriptCallback?
    var onDestroyHandler: ScriptCallback?

    public init(
        onStart: ScriptCallback? = nil,
        onTick: ScriptCallback? = nil,
        onDestroy: ScriptCallback? = nil
    ) {
        self.onStartHandler = onStart
        self.onTickHandler = onTick
        self.onDestroyHandler = onDestroy
    }

    public func onStart(_ handler: @escaping ScriptCallback) -> Script {
        var script = self
        script.onStartHandler = handler
        return script
    }

    public func onTick(_ handler: @escaping ScriptCallback) -> Script {
        var script = self
        script.onTickHandler = handler
        return script
    }

    public func onDestroy(_ handler: @escaping ScriptCallback) -> Script {
        var script = self
        script.onDestroyHandler = handler
        return script
    }
}