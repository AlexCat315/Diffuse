import Foundation

public protocol ScriptBehavior: Sendable {
    init()

    mutating func onStart(_ context: ScriptContext)
    mutating func onPrePhysics(_ context: ScriptContext)
    mutating func onUpdate(_ context: ScriptContext)
    mutating func onDestroy(_ context: ScriptContext)
}

/// Optional property contract, independent of the executable lifecycle.
public protocol ScriptAuthoring {
    static var definition: ScriptDefinition { get }
}

public extension ScriptBehavior {
    mutating func onStart(_ context: ScriptContext) {}
    mutating func onPrePhysics(_ context: ScriptContext) {}
    mutating func onUpdate(_ context: ScriptContext) {}
    mutating func onDestroy(_ context: ScriptContext) {}
}

private final class ScriptBehaviorState<Behavior: ScriptBehavior>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var behavior: Behavior

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func withBehavior(_ body: (inout Behavior) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&behavior)
    }
}

public extension Script {
    init<Behavior: ScriptBehavior>(behavior: Behavior.Type) {
        let state = ScriptBehaviorState(Behavior())
        self.init(
            onStart: { context in state.withBehavior { $0.onStart(context) } },
            onPrePhysics: { context in state.withBehavior { $0.onPrePhysics(context) } },
            onTick: { context in state.withBehavior { $0.onUpdate(context) } },
            onDestroy: { context in state.withBehavior { $0.onDestroy(context) } }
        )
    }
}

extension Script {
    func retaining<Lifetime: Sendable>(_ lifetime: Lifetime) -> Script {
         Script(onStart: retainingCallback(onStartHandler, lifetime: lifetime),
             onPrePhysics: retainingCallback(onPrePhysicsHandler, lifetime: lifetime),
             onTick: retainingCallback(onTickHandler, lifetime: lifetime),
             onDestroy: retainingCallback(onDestroyHandler, lifetime: lifetime))
    }
}

private func retainingCallback<Lifetime: Sendable>(_ callback: ScriptCallback?,
                                                   lifetime: Lifetime) -> ScriptCallback? {
    guard let callback else { return nil }
    return { [lifetime] context in
        _ = lifetime
        callback(context)
    }
}
