public typealias ScriptCallback = @Sendable (ScriptContext) -> Void

public struct Script: Sendable {
    var onStartHandler: ScriptCallback?
    var onPrePhysicsHandler: ScriptCallback?
    var onTickHandler: ScriptCallback?
    var onDestroyHandler: ScriptCallback?

    public init(
        onStart: ScriptCallback? = nil,
        onPrePhysics: ScriptCallback? = nil,
        onTick: ScriptCallback? = nil,
        onDestroy: ScriptCallback? = nil
    ) {
        self.onStartHandler = onStart
        self.onPrePhysicsHandler = onPrePhysics
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

    /// Runs once per rendered frame after input processing and before physics sync.
    /// Use this phase to submit forces, impulses and character commands that must affect
    /// the current frame's fixed physics steps.
    public func onPrePhysics(_ handler: @escaping ScriptCallback) -> Script {
        var script = self
        script.onPrePhysicsHandler = handler
        return script
    }

    /// Post-physics frame update. This is the Physics v2 spelling of `onTick`.
    public func onUpdate(_ handler: @escaping ScriptCallback) -> Script {
        onTick(handler)
    }

    public func onDestroy(_ handler: @escaping ScriptCallback) -> Script {
        var script = self
        script.onDestroyHandler = handler
        return script
    }
}
