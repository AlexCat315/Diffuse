import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat
import Foundation

private final class ScriptReloadRecorder: @unchecked Sendable {
    var firstStarts = 0
    var firstTicks = 0
    var firstDestroys = 0
    var secondStarts = 0
    var secondTicks = 0
}

@Suite("Script catalog runtime")
struct ScriptCatalogRuntimeTests {
    @Test("stable identifiers resolve independently of serialized handles")
    func stableIdentifierResolution() {
        let scripts = ScriptRuntime()
        _ = scripts.register(named: "project.move") {
            Script.mover(velocity: SIMD3<Float>(1, 0, 0))
        }
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(), for: entity)
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(ScriptHandle(rawValue: 999),
                                          identifier: "project.move")),
            for: entity
        )

        _ = runtime.tick(deltaTime: 0.5)

        #expect(runtime.localTransform(for: entity)?.translation.x == 0.5)
    }

    @Test("script factories isolate captured state for every binding instance")
    func factoriesCreatePerBindingState() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "project.stateful") {
            let elapsedTicks = ScriptVar<Float>(0)
            return Script().onTick { context in
                elapsedTicks.value += 1
                context.translate(by: SIMD3<Float>(elapsedTicks.value, 0, 0))
            }
        }
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let first = runtime.createEntity()
        let second = runtime.createEntity()
        for entity in [first, second] {
            _ = runtime.setLocalTransform(LocalTransform(), for: entity)
            _ = runtime.setComponent(ScriptComponent(handle), for: entity)
        }

        _ = runtime.tick(deltaTime: 0.1)
        _ = runtime.tick(deltaTime: 0.1)

        #expect(runtime.localTransform(for: first)?.translation.x == 3)
        #expect(runtime.localTransform(for: second)?.translation.x == 3)
    }

    @Test("hot replacement destroys the old instance and starts the replacement")
    func namedRegistrationHotReplacement() {
        let recorder = ScriptReloadRecorder()
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "project.reload") {
            Script()
                .onStart { _ in recorder.firstStarts += 1 }
                .onTick { _ in recorder.firstTicks += 1 }
                .onDestroy { _ in recorder.firstDestroys += 1 }
        }
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let entity = runtime.createEntity()
        _ = runtime.setComponent(ScriptComponent(handle), for: entity)
        _ = runtime.tick(deltaTime: 0.1)

        let replacementHandle = scripts.register(named: "project.reload") {
            Script()
                .onStart { _ in recorder.secondStarts += 1 }
                .onTick { _ in recorder.secondTicks += 1 }
        }
        _ = runtime.tick(deltaTime: 0.1)

        #expect(replacementHandle == handle)
        #expect(recorder.firstStarts == 1)
        #expect(recorder.firstTicks == 1)
        #expect(recorder.firstDestroys == 1)
        #expect(recorder.secondStarts == 1)
        #expect(recorder.secondTicks == 1)
    }

    @Test("binding parameters override catalog defaults without discarding other defaults")
    func bindingParametersMergeWithDefaults() {
        let observedSpeed = ScriptVar<Float>(0)
        let observedMode = ScriptVar<String>("")
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "project.parameters",
                                      defaultParametersJSON: #"{"speed":2,"mode":"walk"}"#) {
            Script().onTick { context in
                observedSpeed.value = context.floatParameter("speed") ?? 0
                observedMode.value = context.stringParameter("mode") ?? ""
            }
        }
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let entity = runtime.createEntity()
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(handle, parametersJSON: #"{"speed":3}"#)),
            for: entity
        )

        _ = runtime.tick(deltaTime: 0.1)

        #expect(observedSpeed.value == 3)
        #expect(observedMode.value == "walk")
    }

    @Test("full scene serialization preserves stable script identifiers")
    func fullSceneSerializationPreservesIdentifiers() throws {
        var source = SceneRuntime()
        let entity = source.createEntity()
        _ = source.setComponent(
            ScriptComponent(ScriptBinding(identifier: "project.persisted",
                                          isEnabled: false,
                                          parametersJSON: #"{"speed":4}"#)),
            for: entity
        )

        let data = try SceneSerializer.serializeFull(source)
        var restored = SceneRuntime()
        try SceneSerializer.deserializeFull(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        let binding = try #require(
            restored.component(ScriptComponent.self, for: restoredEntity)?.bindings.first
        )

        #expect(binding.identifier == "project.persisted")
        #expect(!binding.isEnabled)
        #expect(binding.parametersJSON == #"{"speed":4}"#)
        #expect(binding.script.rawValue == 0)
    }

    @Test("full scene serialization keeps scripts aligned when derived fragments are omitted")
    func fullSceneSerializationSkipsDerivedFragmentsWithoutShiftingBindings() throws {
        var source = SceneRuntime()
        let destructionSource = source.createEntity()
        let derivedFragment = source.createEntity()
        _ = source.setComponent(
            DestructibleFragment(
                sourceEntity: destructionSource,
                fragmentID: 0,
                spawnedAtSeconds: 0,
                maximumLifetimeSeconds: 1,
                sleepingRecycleDelaySeconds: 1
            ),
            for: derivedFragment
        )
        let scriptedEntity = source.createEntity()
        _ = source.setComponent(SceneNameComponent(value: "Scripted"), for: scriptedEntity)
        _ = source.setComponent(
            ScriptComponent(ScriptBinding(identifier: "project.after-fragment")),
            for: scriptedEntity
        )

        let data = try SceneSerializer.serializeFull(source)
        var restored = SceneRuntime()
        try SceneSerializer.deserializeFull(data, into: &restored)

        #expect(restored.entities().count == 2)
        #expect(restored.entities(with: DestructibleFragment.self).isEmpty)
        let restoredScripted = try #require(restored.entities().first {
            restored.component(SceneNameComponent.self, for: $0)?.value == "Scripted"
        })
        #expect(
            restored.component(ScriptComponent.self, for: restoredScripted)?
                .bindings.first?.identifier == "project.after-fragment"
        )
        let restoredSource = try #require(restored.entities().first { $0 != restoredScripted })
        #expect(restored.component(ScriptComponent.self, for: restoredSource) == nil)
    }

    @Test("full scene deserialization attaches scripts only to newly loaded entities")
    func fullSceneDeserializationIntoPopulatedWorldUsesReturnedEntityMap() throws {
        var source = SceneRuntime()
        let scriptedEntity = source.createEntity()
        _ = source.setComponent(
            ScriptComponent(ScriptBinding(identifier: "project.loaded")),
            for: scriptedEntity
        )
        let data = try SceneSerializer.serializeFull(source)

        var restored = SceneRuntime()
        let existing = restored.createEntity()
        _ = restored.setComponent(SceneNameComponent(value: "Existing"), for: existing)
        try SceneSerializer.deserializeFull(data, into: &restored)

        #expect(restored.component(ScriptComponent.self, for: existing) == nil)
        let loaded = try #require(restored.entities().first { $0 != existing })
        #expect(
            restored.component(ScriptComponent.self, for: loaded)?
                .bindings.first?.identifier == "project.loaded"
        )
    }
}
