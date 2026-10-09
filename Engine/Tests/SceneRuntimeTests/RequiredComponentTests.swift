import Foundation
import SIMDCompat
import Testing
@testable import SceneRuntime

@Suite("Required components")
struct RequiredComponentTests {
    @Test("spatial component writes insert transforms and preserve authored transforms")
    func spatialDefaults() throws {
        var world = RuntimeWorld()
        try world.componentRegistry.validateRequirements()
        let camera = world.createEntity()
        let cameraInserted = world.setComponent(CameraComponent(), for: camera)
        #expect(cameraInserted)
        #expect(world.component(LocalTransform.self, for: camera) == .identity)
        let authored = LocalTransform(translation: SIMD3(2, 3, 4))
        let transformUpdated = world.setLocalTransform(authored, for: camera)
        let cameraUpdated = world.setComponent(CameraComponent(near: 0.5), for: camera)
        #expect(transformUpdated && cameraUpdated)
        #expect(world.component(LocalTransform.self, for: camera) == authored)
        _ = world.removeComponent(CameraComponent.self, from: camera)
        #expect(world.component(LocalTransform.self, for: camera) == authored)

        let light = world.createEntity()
        let lightInserted = world.setComponent(LightComponent(), for: light)
        #expect(lightInserted)
        #expect(world.component(LocalTransform.self, for: light) == .identity)
        world.propagateTransforms()
        #expect(world.worldTransform(for: camera)?.translation == authored.translation)
        #expect(world.worldTransform(for: light)?.translation == .zero)
    }

    @Test("forward declarations and diamond dependencies have deterministic insertion order")
    func transitiveDefaults() throws {
        var registry = dependencyRegistry()
        #expect(throws: ComponentDependencyError.missingRequirement(component: "test.left", required: "test.leaf")) {
            try registry.validateRequirements()
        }
        registry.register(testSchema(RequiredLeaf.self, id: "test.leaf", value: 7))
        try registry.validateRequirements()
        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        try scene.addComponent(typeID: "test.root", for: entity)
        #expect(scene.resource(RequiredCreationLog.self)?.ids == ["test.leaf", "test.left", "test.right", "test.root"])
        #expect(scene.component(RequiredLeaf.self, for: entity)?.value == 7)
        let copy = scene
        _ = scene.setComponent(RequiredLeaf(value: 99), for: entity)
        _ = scene.removeComponent(RequiredRoot.self, from: entity)
        try scene.addComponent(typeID: "test.root", for: entity)
        #expect(scene.component(RequiredLeaf.self, for: entity)?.value == 99)
        #expect(scene.resource(RequiredCreationLog.self)?.ids == ["test.leaf", "test.left", "test.right", "test.root", "test.root"])
        #expect(copy.component(RequiredLeaf.self, for: entity)?.value == 7)
    }

    @Test("missing requirements, cycles and unavailable defaults reject atomically")
    func invalidDependencies() throws {
        var missing = dependencyRegistry()
        var cyclic = ComponentRegistry()
        cyclic.register(testSchema(RequiredRoot.self, id: "test.root", requires: ["test.left"]))
        cyclic.register(testSchema(RequiredLeft.self, id: "test.left", requires: ["test.root"]))
        #expect(throws: ComponentDependencyError.cycle(["test.root", "test.left", "test.root"])) {
            try cyclic.validateRequirements()
        }
        missing.register(testSchema(RequiredLeaf.self, id: "test.leaf", unavailable: true))
        for registry in [dependencyRegistry(), cyclic, missing] {
            var scene = SceneRuntime(componentRegistry: registry)
            let entity = scene.createEntity()
            let revision = scene.snapshot.revision
            let inserted = scene.setComponent(RequiredRoot(value: 2), for: entity)
            #expect(!inserted)
            #expect(throws: (any Error).self) { try scene.addComponent(typeID: "test.root", for: entity) }
            #expect(!scene.hasComponent(RequiredRoot.self, for: entity))
            #expect(!scene.hasComponent(RequiredLeaf.self, for: entity))
            #expect(scene.resource(RequiredCreationLog.self) == nil)
            #expect(scene.snapshot.revision == revision)
        }
    }

    @Test("failed dependency defaults roll back earlier dependencies and conflicts")
    func partialDependencyFailure() throws {
        var registry = ComponentRegistry()
        registry.register(testSchema(RequiredRoot.self, id: "test.root", requires: ["test.left", "test.right"]))
        registry.register(testSchema(RequiredLeft.self, id: "test.left"))
        registry.register(testSchema(RequiredRight.self, id: "test.right", unavailable: true))
        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        let revision = scene.snapshot.revision
        #expect(throws: ComponentDependencyError.defaultUnavailable("test.right")) {
            try scene.addComponent(typeID: "test.root", for: entity)
        }
        #expect(!scene.hasComponent(RequiredLeft.self, for: entity))
        #expect(scene.resource(RequiredCreationLog.self) == nil)
        #expect(scene.snapshot.revision == revision)
        let inserted = scene.setComponent(RequiredRoot(value: 2), for: entity)
        #expect(!inserted)
        #expect(scene.snapshot.revision == revision)

        for leftDeclaresConflict in [true, false] {
            var conflicting = ComponentRegistry()
            conflicting.register(testSchema(RequiredRoot.self, id: "test.root", requires: ["test.left", "test.right"]))
            conflicting.register(testSchema(RequiredLeft.self, id: "test.left",
                incompatibleWith: leftDeclaresConflict ? ["test.right"] : []))
            conflicting.register(testSchema(RequiredRight.self, id: "test.right",
                incompatibleWith: leftDeclaresConflict ? [] : ["test.left"]))
            var rejected = SceneRuntime(componentRegistry: conflicting)
            let rejectedEntity = rejected.createEntity()
            let conflictingInsert = rejected.setComponent(RequiredRoot(value: 2), for: rejectedEntity)
            #expect(!conflictingInsert)
            #expect(!rejected.hasComponent(RequiredLeft.self, for: rejectedEntity))
        }
    }

    @Test("decode, prefab and save flows supply dependencies without persisting a second transform")
    func documentDefaults() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var context = ComponentDecodeContext(entityMap: [0: entity])
        SceneSerializer.applyComponentDocument([ManifestComponent(type: "camera", value: .object([:]))],
            to: entity, in: &scene, context: &context)
        #expect(scene.component(LocalTransform.self, for: entity) == .identity)
        let data = try SceneSerializer.serialize(scene)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(document["entities"] as? [[String: Any]])
        #expect((records[0]["components"] as? [String: Any])?["localTransform"] == nil)
        #expect(records[0]["translation"] != nil)

        var registry = dependencyRegistry()
        registry.register(testSchema(RequiredLeaf.self, id: "test.leaf", value: 7))
        var custom = SceneRuntime(componentRegistry: registry)
        let root = custom.createEntity()
        try custom.setComponentData(.object(["value": .number(31)]), typeID: "test.root", for: root)
        _ = custom.setComponent(RequiredLeaf(value: 99), for: root)
        let prefab = try #require(try Prefab.capture(from: custom, root: root))
        let copy = try #require(try prefab.instantiate(into: &custom))
        #expect(custom.component(RequiredLeaf.self, for: copy)?.value == 99)
        #expect(custom.component(RequiredRoot.self, for: copy)?.value == 31)
        let save = try GameSave.capture(scene: custom)
        var restored = SceneRuntime(componentRegistry: registry)
        try save.restoreScene(into: &restored)
        #expect(restored.entities().allSatisfy { restored.component(RequiredLeaf.self, for: $0)?.value == 99 })
    }

    @Test("document-provided dependencies are available when constructing missing transitive defaults")
    func explicitDependencyPrecedence() throws {
        var registry = ComponentRegistry()
        registry.register(testSchema(RequiredRoot.self, id: "test.root", requires: ["test.left"]))
        let left = testSchema(RequiredLeft.self, id: "test.left")
        registry.register(ComponentSchema(RequiredLeft.self, typeID: "test.left", displayName: "Left", category: .gameplay,
            encode: left.encode, decode: left.decode,
            makeDefault: { entity, world in
                _ = world.setComponent(RequiredLeft(value: world.component(RequiredLeaf.self, for: entity)?.value ?? -1), for: entity)
            }, configure: { $0.requires = ["test.leaf"] }))
        registry.register(testSchema(RequiredLeaf.self, id: "test.leaf", value: 7))
        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        var context = ComponentDecodeContext(entityMap: [0: entity])
        SceneSerializer.applyComponentDocument([
            ManifestComponent(type: "test.root", value: .object([:])),
            ManifestComponent(type: "test.leaf", value: .object(["value": .number(99)])),
        ], to: entity, in: &scene, context: &context)
        #expect(scene.component(RequiredLeaf.self, for: entity)?.value == 99)
        #expect(scene.component(RequiredLeft.self, for: entity)?.value == 99)
    }
}

private protocol RequiredTestValue: RuntimeComponent, Equatable {
    var value: Int { get }
    init(value: Int)
}
private struct RequiredRoot: RequiredTestValue { var value: Int }
private struct RequiredLeft: RequiredTestValue { var value: Int }
private struct RequiredRight: RequiredTestValue { var value: Int }
private struct RequiredLeaf: RequiredTestValue { var value: Int }
private struct RequiredCreationLog: Sendable { var ids: [String] = [] }

private func dependencyRegistry() -> ComponentRegistry {
    var registry = ComponentRegistry()
    registry.register(testSchema(RequiredRoot.self, id: "test.root", requires: ["test.left", "test.right"]))
    registry.register(testSchema(RequiredLeft.self, id: "test.left", requires: ["test.leaf"]))
    registry.register(testSchema(RequiredRight.self, id: "test.right", requires: ["test.leaf"]))
    return registry
}

private func testSchema<Value: RequiredTestValue>(_ type: Value.Type, id: String,
    requires: [String] = [], value: Int = 0, unavailable: Bool = false,
    incompatibleWith: [String] = []) -> ComponentSchema {
    ComponentSchema(type, typeID: id, displayName: id, category: .gameplay,
        encode: { world, entity, _ in
            world.component(type, for: entity).map { .object(["value": .signedInteger(Int64($0.value))]) }
        }, decode: { data, entity, _, world in
            _ = world.setComponent(Value(value: (data.objectValue?["value"] as? NSNumber)?.intValue ?? value), for: entity)
        }, makeDefault: { entity, world in
            var log = world.resource(RequiredCreationLog.self) ?? RequiredCreationLog()
            log.ids.append(id)
            world.setResource(log)
            if !unavailable { _ = world.setComponent(Value(value: value), for: entity) }
        }, configure: { $0.requires = requires; $0.incompatibleWith = incompatibleWith })
}
