import Foundation
import IntentRuntime
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing

@Suite("Registry component transactions")
struct ComponentTransactionTests {
    @Test("normalized verification follows removal, default insertion and later indexed edits", arguments: [false, true])
    func normalizedComponentRecreation(existing: Bool) throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        if existing { _ = scene.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 2, fixedVertexIndices: [0, 2, 5]), for: entity) }
        let index: ComponentValue = .object(["fixedVertexIndices": .object(["0": .number(5)])])
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let removal: [TransactionOperation] = existing ? [.scene(.removeComponentData(entityID: entity.rawValue, typeID: "cloth"))] : []
        let absent: [TransactionVerificationAssertion] = existing ? [.componentPresence(entityID: entity.rawValue, typeID: "cloth", isPresent: false)] : []
        _ = try TransactionExecutor().apply(TransactionIR(summary: "Recreate cloth", operations: removal + [
            .scene(.addComponent(entityID: entity.rawValue, typeID: "cloth")),
            .scene(.setComponentData(entityID: entity.rawValue, typeID: "cloth", value: index, mode: .merge)),
        ], verificationAssertions: absent + [
            .componentPresence(entityID: entity.rawValue, typeID: "cloth", isPresent: true),
            .componentData(entityID: entity.rawValue, typeID: "cloth", value: index, mode: .merge),
        ], provenance: .authored), to: &context)
        #expect(context.sceneRuntime?.component(Cloth.self, for: entity)?.fixedVertexIndices == Array(1..<16))
        #expect(context.sceneRuntime?.component(Cloth.self, for: entity)?.gridSizeX == 16)
    }

    @Test("normalized component input verifies canonical arrays and publishes canonical events")
    func normalizedInputVerification() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 2, fixedVertexIndices: [0, 2, 5]), for: entity)
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let patch: ComponentValue = .object(["fixedVertexIndices": .object(["2": .number(1)])])
        let result = try TransactionExecutor().apply(TransactionIR(summary: "Edit fixed points",
            operations: [.scene(.setComponentData(entityID: entity.rawValue, typeID: "cloth", value: patch, mode: .merge))],
            verificationAssertions: [.componentData(entityID: entity.rawValue, typeID: "cloth", value: patch, mode: .merge)],
            provenance: .authored), to: &context)
        #expect(context.sceneRuntime?.component(Cloth.self, for: entity)?.fixedVertexIndices == [0, 1, 2])
        #expect(result.worldEvents.contains {
            if case let .entityAuthoredChanged(_, "components.cloth", .json(data)) = $0 {
                return data.value(at: ["fixedVertexIndices"]) == .array([0, 1, 2].map { .number(Double($0)) })
            }
            return false
        })
        let edits: [ComponentValue] = [
            .object(["fixedVertexIndices": .object(["2": .number(0)])]),
            .object(["fixedVertexIndices": .object(["1": .number(4)])]),
        ]
        _ = try TransactionExecutor().apply(TransactionIR(summary: "Sequential canonical indices",
            operations: edits.map { .scene(.setComponentData(entityID: entity.rawValue, typeID: "cloth", value: $0, mode: .merge)) },
            verificationAssertions: edits.map { .componentData(entityID: entity.rawValue, typeID: "cloth", value: $0, mode: .merge) },
            provenance: .authored), to: &context)
        #expect(context.sceneRuntime?.component(Cloth.self, for: entity)?.fixedVertexIndices == [0, 4])
        let fixed: ComponentValue = .object(["fixedVertexIndices": .array([5, 2, -1, 2, 999].map { .number(Double($0)) })])
        let grid: ComponentValue = .object(["gridSizeX": .number(2)])
        _ = try TransactionExecutor().apply(TransactionIR(summary: "Resize edited topology", operations: [
            .scene(.setComponentData(entityID: entity.rawValue, typeID: "cloth", value: fixed, mode: .merge)),
            .scene(.setComponentData(entityID: entity.rawValue, typeID: "cloth", value: grid, mode: .merge)),
        ], verificationAssertions: [
            .componentData(entityID: entity.rawValue, typeID: "cloth", value: fixed, mode: .merge),
            .componentData(entityID: entity.rawValue, typeID: "cloth", value: grid, mode: .merge),
        ], provenance: .authored), to: &context)
        #expect(context.sceneRuntime?.component(Cloth.self, for: entity)?.fixedVertexIndices == [2])
        let before = try SceneSerializer.serialize(try #require(context.sceneRuntime))
        #expect(throws: TransactionExecutorError.self) {
            try TransactionExecutor().apply(TransactionIR(summary: "Incorrect postcondition",
                operations: [.scene(.setComponentData(entityID: entity.rawValue, typeID: "cloth", value: grid, mode: .merge))],
                verificationAssertions: [.componentData(entityID: entity.rawValue, typeID: "cloth",
                    value: .object(["gridSizeX": .number(4)]), mode: .merge)], provenance: .authored), to: &context)
        }
        #expect(try SceneSerializer.serialize(try #require(context.sceneRuntime)) == before)
    }

    @Test("component dependencies participate in transactions and produce component events")
    func requiredComponentEvents() throws {
        var scene = SceneRuntime()
        var counter = transactionCounterSchema
        counter.requires = ["light"]
        scene.componentRegistry.register(counter)
        let entity = scene.createEntity()
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try TransactionExecutor().apply(TransactionIR(summary: "Add with dependencies", operations: [
            .scene(.addComponent(entityID: entity.rawValue, typeID: "test.counter")),
        ], provenance: .authored), to: &context)
        #expect(context.sceneRuntime?.hasComponent(LightComponent.self, for: entity) == true)
        #expect(context.sceneRuntime?.component(LocalTransform.self, for: entity) == .identity)
        #expect(result.worldEvents.contains {
            if case .entityAuthoredChanged(_, "components.light", .json) = $0 { return true }
            return false
        })
    }

    @Test("camera and light spawn events report effective registry defaults and explicit overrides")
    func spawnRegistryDefaults() throws {
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())
        let result = try TransactionExecutor().apply(TransactionIR(summary: "Create registry defaults", operations: [
            .scene(.spawnLightEntity(label: "Light", lightType: .spot, position: .zero, initialIntensity: 17)),
            .scene(.spawnCameraEntity(label: "Camera", position: .zero)),
        ], provenance: .authored), to: &context)
        let scene = try #require(context.sceneRuntime)
        let light = EntityID(rawValue: result.createdEntityIDs[0])
        let camera = EntityID(rawValue: result.createdEntityIDs[1])
        #expect(scene.component(LightComponent.self, for: light)?.intensity == 17)
        #expect(scene.component(LightComponent.self, for: light)?.type == .spot)
        let value = try #require(scene.componentData("camera", for: camera))
        #expect(result.worldEvents.contains {
            if case let .entityAuthoredChanged(_, "components.camera", .json(data)) = $0 { return data == value }
            return false
        })
    }

    @Test("a contributed component supports add, sequential nested edits, duplication and removal")
    func contributedComponentLifecycle() throws {
        var scene = SceneRuntime()
        scene.componentRegistry.register(transactionCounterSchema)
        let entity = scene.createEntity()
        let id = entity.rawValue
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let executor = TransactionExecutor()
        let operations: [TransactionOperation] = [
            .scene(.addComponent(entityID: id, typeID: "test.counter")),
            .scene(.componentFields(entityID: id, typeID: "test.counter", fields: ["value": 42])),
            .scene(.componentFields(entityID: id, typeID: "test.counter", fields: ["options": ["enabled": false]])),
            .scene(.componentFields(entityID: id, typeID: "test.counter", fields: ["value": 81])),
            .scene(.duplicateEntity(entityID: id)),
        ]
        let result = try executor.apply(TransactionIR(summary: "Edit contributed component",
            operations: operations, provenance: .authored), to: &context)
        let restored = try #require(context.sceneRuntime)
        #expect(restored.component(TransactionCounter.self, for: entity) == TransactionCounter(value: 81, enabled: false))
        let copy = EntityID(rawValue: try #require(result.createdEntityIDs.first))
        #expect(restored.component(TransactionCounter.self, for: copy) == restored.component(TransactionCounter.self, for: entity))
        #expect(result.worldEvents.contains {
            if case let .entityAuthoredChanged(_, "components.test.counter", .json(data)) = $0 {
                return data.containsFields(ComponentValue(jsonObject: ["value": 81]))
            }
            return false
        })
        _ = try executor.apply(TransactionIR(summary: "Remove contributed component",
            operations: [.scene(.removeComponentData(entityID: id, typeID: "test.counter"))],
            provenance: .authored), to: &context)
        #expect(context.sceneRuntime?.hasComponent(TransactionCounter.self, for: entity) == false)
        #expect(context.sceneRuntime?.hasComponent(TransactionCounter.self, for: copy) == true)
    }

    @Test("an invalid component write rolls back preceding structural and component edits")
    func atomicFailure() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(), for: entity)
        let before = try SceneSerializer.serialize(scene)
        for invalid in [SceneMutation.setComponentData(entityID: entity.rawValue, typeID: "unknown", value: .object([:])),
                        .setComponentData(entityID: entity.rawValue, typeID: "light", value: .null),
                        .setComponentData(entityID: entity.rawValue, typeID: "light", value: .object(["typo": .bool(true)])),
                        .setComponentData(entityID: UInt64.max, typeID: "light", value: .object([:]))] {
            var context = TransactionExecutionContext(sceneRuntime: scene)
            let transaction = TransactionIR(summary: "Must roll back", operations: [
                .scene(.spawnEmptyEntity(label: "Temporary", position: .zero)),
                .scene(.componentFields(entityID: entity.rawValue, typeID: "light", fields: ["intensity": Float(7)])),
                .scene(invalid),
            ], provenance: .authored)
            #expect(throws: (any Error).self) { try TransactionExecutor().apply(transaction, to: &context) }
            #expect(try SceneSerializer.serialize(try #require(context.sceneRuntime)) == before)
        }
    }

    @Test("non-finite numbers and out-of-range integer fields reject without trapping")
    func invalidNumericValues() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: entity)
        let before = try #require(scene.componentData("collider", for: entity))
        for value in [ComponentValue.object(["layerID": .number(65_536)]),
                      .object(["layerMask": .number(-1)]),
                      .object(["friction": .number(.infinity)]),
                      .object(["friction": .number(.nan)])] {
            #expect(throws: ComponentEditError.self) {
                try scene.setComponentData(value, typeID: "collider", for: entity, mode: .merge)
            }
            #expect(scene.componentData("collider", for: entity) == before)
        }
    }

    @Test("compound shape field edits preserve other instances and their transforms")
    func compoundColliderEditing() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let second = ColliderShapeInstance(shape: .box(halfExtents: SIMD3(repeating: 2), center: .zero),
                                           localPosition: SIMD3(3, 4, 5))
        _ = scene.setComponent(Collider(shapes: [
            ColliderShapeInstance(shape: .sphere(radius: 1, center: SIMD3(1, 2, 3))), second,
        ]), for: entity)
        try scene.setComponentData(ComponentValue(jsonObject: ["shapes": ["0": ["radius": Float(4)]]]),
                                   typeID: "collider", for: entity, mode: .merge)
        let edited = try #require(scene.component(Collider.self, for: entity))
        #expect(edited.shapes[1] == second)
        #expect(edited.shape == .sphere(radius: 4, center: SIMD3(1, 2, 3)))
        let before = try #require(scene.componentData("collider", for: entity))
        #expect(throws: ComponentEditError.invalidArrayIndex("9")) {
            try scene.setComponentData(ComponentValue(jsonObject: ["shapes": ["9": ["radius": 4]]]),
                                       typeID: "collider", for: entity, mode: .merge)
        }
        #expect(scene.componentData("collider", for: entity) == before)
    }

    @Test("reference edits use entity generations and duplication remaps self references")
    func referenceIdentity() throws {
        var scene = SceneRuntime()
        let removed = scene.createEntity()
        _ = scene.destroyEntity(removed)
        let target = scene.createEntity()
        let joint = scene.createEntity()
        _ = scene.setComponent(Constraint(entityA: joint, entityB: target), for: joint)
        let data = try #require(scene.componentData("constraint", for: joint))
        let unrelated = scene.createEntity()
        _ = scene.destroyEntity(unrelated)
        try scene.setComponentData(data, typeID: "constraint", for: joint)
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try TransactionExecutor().apply(TransactionIR(summary: "Duplicate reference component",
            operations: [.scene(.duplicateEntity(entityID: joint.rawValue))], provenance: .authored), to: &context)
        let copy = EntityID(rawValue: try #require(result.createdEntityIDs.first))
        let constraint = try #require(context.sceneRuntime?.component(Constraint.self, for: copy))
        #expect(constraint.entityA == copy)
        #expect(constraint.entityB == target)
        #expect(target.generation != removed.generation)
        #expect(throws: ComponentEditError.self) {
            try scene.setComponentData(ComponentValue(jsonObject: ["entityB": Int(bitPattern: UInt(removed.rawValue))]),
                                       typeID: "constraint", for: joint, mode: .merge)
        }
        #expect(scene.component(Constraint.self, for: joint)?.entityB == target)
    }

    @Test("particle edits retain the running pool and RNG while reseeding resets simulation")
    func particleSimulationState() throws {
        var emitter = ParticleEmitter(settings: .init { $0.emission.seed = 345 })
        emitter.emit(5)
        var expected = emitter
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(emitter, for: entity)
        let edit = ComponentValue(jsonObject: ["settings": ["emission": ["emissionRate": Float(8)]]])
        try scene.setComponentData(edit, typeID: "particleEmitter", for: entity, mode: .merge)
        var actual = try #require(scene.component(ParticleEmitter.self, for: entity))
        #expect(actual.particles == emitter.particles)
        expected.settings.emission.emissionRate = 8
        actual.emit(3)
        expected.emit(3)
        #expect(actual.particles == expected.particles)
        try scene.setComponentData(ComponentValue(jsonObject: ["settings": ["emission": ["seed": UInt64.max]]]),
                                   typeID: "particleEmitter", for: entity, mode: .merge)
        #expect(scene.component(ParticleEmitter.self, for: entity)?.particles.isEmpty == true)
        #expect(scene.component(ParticleEmitter.self, for: entity)?.settings.emission.seed == UInt64.max)
    }
}

private struct TransactionCounter: RuntimeComponent, Equatable {
    var value: Int
    var enabled: Bool
}

private let transactionCounterSchema = ComponentSchema(TransactionCounter.self, typeID: "test.counter",
    displayName: "Counter", category: .gameplay,
    encode: { world, entity, _ in
        world.component(TransactionCounter.self, for: entity).map {
            ComponentValue(jsonObject: ["value": $0.value, "options": ["enabled": $0.enabled]])
        }
    }, decode: { value, entity, _, world in
        guard let data = value.objectValue else { return }
        let options = data["options"] as? [String: Any]
        _ = world.setComponent(TransactionCounter(value: (data["value"] as? NSNumber)?.intValue ?? 7,
                                                 enabled: options?["enabled"] as? Bool ?? true), for: entity)
    }, makeDefault: { entity, world in
        _ = world.setComponent(TransactionCounter(value: 7, enabled: true), for: entity)
    })

extension ComponentTransactionTests {
    @Test("script edits retain live handles while scene persistence excludes them")
    func scriptHandleBoundary() throws {
        var registry = ComponentRegistry.builtIn
        registry.registerScriptCodec()
        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        let binding = ScriptBinding(ScriptHandle(rawValue: 123), identifier: "project.counter")
        _ = scene.setComponent(ScriptComponent(binding), for: entity)
        var edited = binding
        edited.isEnabled = false
        let value = ComponentValue(jsonObject: ["bindings": [encodeScriptBindingForEditing(edited)]])
        try scene.setComponentData(value, typeID: "script", for: entity)
        #expect(scene.component(ScriptComponent.self, for: entity)?.bindings.first?.script.rawValue == 123)
        #expect(scene.component(ScriptComponent.self, for: entity)?.bindings.first?.isEnabled == false)
        let document = try SceneSerializer.serializeFull(scene)
        #expect(!String(decoding: document, as: UTF8.self).contains("scriptHandle"))
        var restored = SceneRuntime(componentRegistry: registry)
        try SceneSerializer.deserializeFull(document, into: &restored)
        #expect(restored.component(ScriptComponent.self, for: try #require(restored.entities().first))?.bindings.first?.script.rawValue == 0)
    }
}
