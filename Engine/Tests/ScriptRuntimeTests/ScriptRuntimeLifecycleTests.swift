import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

private final class ScriptLifecycleRecorder: @unchecked Sendable {
    var starts = 0
    var ticks = 0
    var destroys = 0
    var tickedInstanceIDs: [Int] = []
    var createdInstances = 0

    func makeInstanceID() -> Int {
        createdInstances += 1
        return createdInstances
    }
}

private struct ScriptHitLog: Sendable, Equatable {
    var entities: [EntityID] = []
}

private struct StatefulScriptBehavior: ScriptBehavior {
    private var updateCount = 0

    mutating func onUpdate(_ context: ScriptContext) {
        updateCount += 1
        _ = context.translate(by: SIMD3<Float>(Float(updateCount), 0, 0))
    }
}

@Suite("ScriptRuntimeLifecycle")
struct ScriptRuntimeLifecycleTests {
    @Test("registered scripts run start once and drive same-frame world updates")
    func registeredScriptsRunLifecycleThroughSceneRuntime() {
        let recorder = ScriptLifecycleRecorder()
        let scripts = ScriptRuntime()
        let script = scripts.register(named: "mover") {
            Script()
                .onStart { _ in
                    recorder.starts += 1
                }
                .onTick { context in
                    recorder.ticks += 1
                    _ = context.translate(by: SIMD3<Float>(Float(context.deltaTime), 0, 0))
                }
                .onDestroy { _ in
                    recorder.destroys += 1
                }
        }

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: entity
        )
        _ = runtime.setComponent(ScriptComponent(script), for: entity)

        _ = runtime.tick(deltaTime: 0.25)
        _ = runtime.tick(deltaTime: 0.5)

        #expect(recorder.starts == 1)
        #expect(recorder.ticks == 2)
        #expect(recorder.destroys == 0)
        #expect(runtime.localTransform(for: entity)?.translation == SIMD3<Float>(0.75, 0, 0))
        #expect(runtime.spatialIndex.entries.first?.bounds.center == SIMD3<Float>(0.75, 0, 0))
    }

    @Test("removing a script binding triggers onDestroy on the next frame")
    func removingScriptBindingTriggersDestroy() {
        let recorder = ScriptLifecycleRecorder()
        let scripts = ScriptRuntime()
        let script = scripts.register(named: "marker") {
            Script()
                .onStart { _ in
                    recorder.starts += 1
                }
                .onDestroy { _ in
                    recorder.destroys += 1
                }
        }

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(ScriptComponent(script), for: entity)

        _ = runtime.tick(deltaTime: 0.1)
        _ = runtime.removeComponent(ScriptComponent.self, from: entity)
        _ = runtime.tick(deltaTime: 0.1)

        #expect(recorder.starts == 1)
        #expect(recorder.destroys == 1)
    }

    @Test("script context exposes direct physics queries")
    func scriptContextExposesPhysicsQueries() {
        let scripts = ScriptRuntime()
        let queryScript = scripts.register(named: "scanner") {
            Script().onTick { context in
                let hit = context.raycast(
                    origin: SIMD3<Float>(-5, 0, 0),
                    direction: SIMD3<Float>(1, 0, 0),
                    maxDistance: 20,
                    filter: PhysicsQueryFilter(layerID: 1, layerMask: 0b0010)
                )
                context.setResource(ScriptHitLog(entities: hit.map { [$0.entity] } ?? []))
            }
        }

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let target = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: target)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0010),
            for: target
        )

        let entity = runtime.createEntity()
        _ = runtime.setComponent(ScriptComponent(queryScript), for: entity)

        _ = runtime.tick(deltaTime: 0.1)

        #expect(runtime.resource(ScriptHitLog.self)?.entities == [target])
    }

    @Test("typed script behaviors keep independent state per binding")
    func typedBehaviorsKeepStatePerBinding() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "typed-counter") {
            Script(behavior: StatefulScriptBehavior.self)
        }

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let firstEntity = runtime.createEntity()
        let secondEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: firstEntity)
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: secondEntity)
        _ = runtime.setComponent(ScriptComponent(handle), for: firstEntity)
        _ = runtime.setComponent(ScriptComponent(handle), for: secondEntity)

        _ = runtime.tick(deltaTime: 0.1)
        _ = runtime.tick(deltaTime: 0.1)

        #expect(runtime.localTransform(for: firstEntity)?.translation == SIMD3<Float>(3, 0, 0))
        #expect(runtime.localTransform(for: secondEntity)?.translation == SIMD3<Float>(3, 0, 0))
    }

    @Test("duplicate script bindings keep their own state when an earlier binding is disabled")
    func duplicateBindingsKeepStableInstances() {
        let recorder = ScriptLifecycleRecorder()
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "duplicate") {
            let instanceID = recorder.makeInstanceID()
            return Script().onTick { _ in
                recorder.tickedInstanceIDs.append(instanceID)
            }
        }

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let entity = runtime.createEntity()
        let first = ScriptBinding(handle)
        let second = ScriptBinding(handle)
        _ = runtime.setComponent(ScriptComponent(bindings: [first, second]), for: entity)

        _ = runtime.tick(deltaTime: 0.1)
        #expect(recorder.tickedInstanceIDs == [1, 2])

        recorder.tickedInstanceIDs.removeAll()
        var disabledFirst = first
        disabledFirst.isEnabled = false
        _ = runtime.setComponent(
            ScriptComponent(bindings: [disabledFirst, second]),
            for: entity
        )
        _ = runtime.tick(deltaTime: 0.1)

        #expect(recorder.tickedInstanceIDs == [2])
        #expect(recorder.createdInstances == 2)
    }
}
