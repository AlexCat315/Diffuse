import EngineKernel
import Foundation
import SceneRuntime

private struct RegisteredScript: Sendable {
    var name: String?
    var generation: UInt64
    var defaultParametersJSON: String
    var makeScript: @Sendable () -> Script
}

private struct ScriptInstanceKey: Hashable, Sendable {
    var entity: EntityID
    var script: ScriptHandle
    var ordinal: Int
}

private struct ActiveScriptInstance: Sendable {
    var registrationGeneration: UInt64
    var script: Script
}

public final class ScriptRuntime: RuntimeScriptDriver, @unchecked Sendable {
    private var nextHandleRawValue: UInt64 = 1
    private var registeredScripts: [ScriptHandle: RegisteredScript] = [:]
    private var handlesByName: [String: ScriptHandle] = [:]
    private var activeInstances: [ScriptInstanceKey: ActiveScriptInstance] = [:]
    private let inputProcessor = InputStateProcessor()
    private let animationRuntime = AnimationRuntime()

    public init() {}

    public func tick(deltaTime: Double) {
        _ = deltaTime
    }

    @discardableResult
    public func register(_ script: Script, named name: String? = nil) -> ScriptHandle {
        register(named: name) { script }
    }

    /// Registers a per-binding script factory. Stateful scripts should use this
    /// overload so every entity/binding receives isolated captured state.
    @discardableResult
    public func register(named name: String? = nil,
                         defaultParametersJSON: String = "{}",
                         _ build: @escaping @Sendable () -> Script) -> ScriptHandle {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedName, !normalizedName.isEmpty,
           let existingHandle = handlesByName[normalizedName],
           var existing = registeredScripts[existingHandle] {
            existing.generation &+= 1
            existing.defaultParametersJSON = defaultParametersJSON
            existing.makeScript = build
            registeredScripts[existingHandle] = existing
            return existingHandle
        }

        let handle = ScriptHandle(rawValue: nextHandleRawValue)
        nextHandleRawValue += 1
        let storedName = normalizedName.flatMap { $0.isEmpty ? nil : $0 }
        registeredScripts[handle] = RegisteredScript(name: storedName,
                                                     generation: 1,
                                                     defaultParametersJSON: defaultParametersJSON,
                                                     makeScript: build)
        if let storedName {
            handlesByName[storedName] = handle
        }
        return handle
    }

    public func handle(named name: String) -> ScriptHandle? {
        handlesByName[name]
    }

    public func identifier(for handle: ScriptHandle) -> String? {
        registeredScripts[handle]?.name
    }

    public var registeredScriptIdentifiers: [String] {
        handlesByName.keys.sorted()
    }

    public func canResolve(_ binding: ScriptBinding) -> Bool {
        resolve(binding) != nil
    }

    public func unregister(_ handle: ScriptHandle) {
        if let name = registeredScripts.removeValue(forKey: handle)?.name {
            handlesByName.removeValue(forKey: name)
        }
        // Keep active instances until the next post-physics phase so onDestroy
        // still receives a valid scene context.
    }

    public func unregister(named name: String) {
        guard let handle = handlesByName[name] else { return }
        unregister(handle)
    }

    public func reset() {
        activeInstances.removeAll(keepingCapacity: true)
        inputProcessor.reset()
    }

    public func run(context: inout RuntimeScriptPhaseContext) {
        prepareFrame(context: &context)
        runPrePhysics(context: &context)
        runPostPhysics(context: &context)
    }

    public func prepareFrame(context: inout RuntimeScriptPhaseContext) {
        context.setResource(InGameCanvas())
        inputProcessor.process(context: &context)
    }

    public func runPrePhysics(context: inout RuntimeScriptPhaseContext) {
        executeBoundScripts(context: context, phase: .prePhysics)
    }

    public func runPostPhysics(context: inout RuntimeScriptPhaseContext) {
        animationRuntime.tick(context: &context, deltaTime: context.deltaTimeSeconds)
        let liveInstances = executeBoundScripts(context: context, phase: .postPhysics)

        for key in Set(activeInstances.keys).subtracting(liveInstances) {
            guard let instance = activeInstances.removeValue(forKey: key) else { continue }
            let scriptContext = ScriptContext(
                phaseContext: context,
                entity: key.entity,
                deltaTime: context.deltaTimeSeconds
            )
            instance.script.onDestroyHandler?(scriptContext)
        }
    }

    private enum ExecutionPhase {
        case prePhysics
        case postPhysics
    }

    @discardableResult
    private func executeBoundScripts(context: RuntimeScriptPhaseContext,
                                     phase: ExecutionPhase) -> Set<ScriptInstanceKey> {
        var liveInstances: Set<ScriptInstanceKey> = []
        for entity in context.entities() {
            guard let scriptComponent = context.component(ScriptComponent.self, for: entity) else {
                continue
            }
            var ordinals: [ScriptHandle: Int] = [:]
            for binding in scriptComponent.bindings where binding.isEnabled {
                guard let (handle, registered) = resolve(binding) else { continue }
                let ordinal = ordinals[handle, default: 0]
                ordinals[handle] = ordinal + 1
                let key = ScriptInstanceKey(entity: entity, script: handle, ordinal: ordinal)
                liveInstances.insert(key)
                let scriptContext = ScriptContext(
                    phaseContext: context,
                    entity: entity,
                    deltaTime: context.deltaTimeSeconds,
                    parametersJSON: binding.parametersJSON,
                    defaultParametersJSON: registered.defaultParametersJSON
                )
                var instance = activeInstances[key]
                if instance?.registrationGeneration != registered.generation {
                    instance?.script.onDestroyHandler?(scriptContext)
                    let replacement = ActiveScriptInstance(
                        registrationGeneration: registered.generation,
                        script: registered.makeScript()
                    )
                    replacement.script.onStartHandler?(scriptContext)
                    activeInstances[key] = replacement
                    instance = replacement
                }
                guard let script = instance?.script else { continue }
                switch phase {
                case .prePhysics:
                    script.onPrePhysicsHandler?(scriptContext)
                case .postPhysics:
                    script.onTickHandler?(scriptContext)
                }
            }
        }
        return liveInstances
    }

    private func resolve(_ binding: ScriptBinding) -> (ScriptHandle, RegisteredScript)? {
        if let identifier = binding.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            guard let handle = handlesByName[identifier],
                  let registered = registeredScripts[handle] else { return nil }
            return (handle, registered)
        }
        guard let registered = registeredScripts[binding.script] else { return nil }
        return (binding.script, registered)
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

    public func physicsOverlapShape(
        in runtime: SceneRuntime,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        runtime.physicsOverlapShape(query, filter: filter)
    }

    public func physicsSweepAABB(
        in runtime: SceneRuntime,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        runtime.physicsSweepAABB(query, filter: filter)
    }

    public func physicsSweepShape(
        in runtime: SceneRuntime,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        runtime.physicsSweepShape(query, filter: filter)
    }
}
