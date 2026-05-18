import EngineKernel
import SceneRuntime

private struct RegisteredScript: Sendable {
    var name: String?
    var script: Script
}

private struct ScriptInstanceKey: Hashable, Sendable {
    var entity: EntityID
    var script: ScriptHandle
    var ordinal: Int
}

public final class ScriptRuntime: RuntimeScriptDriver, @unchecked Sendable {
    private var nextHandleRawValue: UInt64 = 1
    private var registeredScripts: [ScriptHandle: RegisteredScript] = [:]
    private var activeInstances: Set<ScriptInstanceKey> = []
    private let inputProcessor = InputStateProcessor()
    private let animationRuntime = AnimationRuntime()

    public init() {}

    public func tick(deltaTime: Double) {
        _ = deltaTime
    }

    @discardableResult
    public func register(_ script: Script, named name: String? = nil) -> ScriptHandle {
        let handle = ScriptHandle(rawValue: nextHandleRawValue)
        nextHandleRawValue += 1
        registeredScripts[handle] = RegisteredScript(name: name, script: script)
        return handle
    }

    @discardableResult
    public func register(named name: String? = nil, _ build: () -> Script) -> ScriptHandle {
        register(build(), named: name)
    }

    public func unregister(_ handle: ScriptHandle) {
        registeredScripts.removeValue(forKey: handle)
        activeInstances = Set(activeInstances.filter { $0.script != handle })
    }

    public func reset() {
        activeInstances.removeAll(keepingCapacity: true)
        inputProcessor.reset()
    }

    public func run(context: inout RuntimeScriptPhaseContext) {
        context.setResource(InGameCanvas())
        inputProcessor.process(context: &context)
        animationRuntime.tick(context: &context, deltaTime: context.deltaTimeSeconds)
        let entities = context.entities()
        var liveInstances: Set<ScriptInstanceKey> = []

        for entity in entities {
            guard let scriptComponent = context.component(ScriptComponent.self, for: entity) else {
                continue
            }

            var ordinals: [ScriptHandle: Int] = [:]

            for binding in scriptComponent.bindings where binding.isEnabled {
                guard let registered = registeredScripts[binding.script] else {
                    continue
                }

                let ordinal = ordinals[binding.script, default: 0]
                ordinals[binding.script] = ordinal + 1
                let key = ScriptInstanceKey(entity: entity, script: binding.script, ordinal: ordinal)
                let scriptContext = ScriptContext(
                    phaseContext: context,
                    entity: entity,
                    deltaTime: context.deltaTimeSeconds
                )

                liveInstances.insert(key)
                if activeInstances.insert(key).inserted {
                    registered.script.onStartHandler?(scriptContext)
                }
                registered.script.onTickHandler?(scriptContext)
            }
        }

        let endedInstances = activeInstances.subtracting(liveInstances)
        for key in endedInstances {
            guard let registered = registeredScripts[key.script] else {
                continue
            }
            let scriptContext = ScriptContext(
                phaseContext: context,
                entity: key.entity,
                deltaTime: context.deltaTimeSeconds
            )
            registered.script.onDestroyHandler?(scriptContext)
        }
        activeInstances = liveInstances
    }

    public func physicsRaycast(
        in runtime: SceneRuntime,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsRaycastHit? {
        runtime.physicsRaycast(query, filter: filter)
    }

    public func physicsOverlapAABB(
        in runtime: SceneRuntime,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        runtime.physicsOverlapAABB(query, filter: filter)
    }

    public func physicsSweepAABB(
        in runtime: SceneRuntime,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        runtime.physicsSweepAABB(query, filter: filter)
    }
}
