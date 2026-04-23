import SceneRuntime
import ScriptRuntime
import Testing
import simd

private final class ScriptLifecycleRecorder: @unchecked Sendable {
    var starts = 0
    var ticks = 0
    var destroys = 0
}

private struct ScriptHitLog: Sendable, Equatable {
    var entities: [EntityID] = []
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
}