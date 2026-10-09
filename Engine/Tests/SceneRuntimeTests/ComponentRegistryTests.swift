import Foundation
import SIMDCompat
import Testing
@testable import SceneRuntime

@Suite("ComponentRegistry")
struct ComponentRegistryTests {
    @Test("built-in schemas have unique identifiers and omit absent components")
    func identifiersAndAbsence() throws {
        var world = RuntimeWorld()
        let entity = world.createEntity()
        let schemas = world.componentRegistry.schemas
        #expect(!schemas.isEmpty)
        #expect(Set(schemas.map(\.typeID)).count == schemas.count)
        var context = ComponentEncodeContext(entityIndexMap: [entity: 0])
        for schema in schemas {
            #expect(!schema.typeID.isEmpty && !schema.displayName.isEmpty)
            #expect(!schema.has(world, entity))
            #expect(schema.encode(world, entity, &context) == nil)
        }
    }

    @Test("every registered component round-trips canonical JSON and removes through its schema")
    func defaultsRoundTrip() throws {
        for schema in ComponentRegistry.builtIn.schemas {
            var world = RuntimeWorld()
            let entity = world.createEntity()
            let endpoint = world.createEntity()
            var decode = ComponentDecodeContext(entityMap: [0: entity, 1: endpoint])
            if schema.typeID == "constraint" {
                schema.decode(ComponentValue(jsonObject: ["entityA": 0, "entityB": 1]), entity, &decode, &world)
            } else {
                schema.makeDefault(entity, &world)
            }
            #expect(schema.has(world, entity), "missing default for \(schema.typeID)")
            var encode = ComponentEncodeContext(entityIndexMap: [entity: 0, endpoint: 1])
            let value = try #require(schema.encode(world, entity, &encode))
            let bytes = try JSONSerialization.data(withJSONObject: value.jsonObject, options: [.sortedKeys])
            schema.remove(entity, &world)
            #expect(!schema.has(world, entity))
            let parsed = ComponentValue(jsonObject: try JSONSerialization.jsonObject(with: bytes))
            schema.decode(parsed, entity, &decode, &world)
            let restored = try #require(schema.encode(world, entity, &encode))
            #expect(try JSONSerialization.data(withJSONObject: restored.jsonObject, options: [.sortedKeys]) == bytes,
                    "round-trip drifted for \(schema.typeID)")
        }
    }

    @Test("missing component fields rebuild defaults with deterministic particle settings")
    func missingFields() throws {
        var world = RuntimeWorld()
        let entity = world.createEntity()
        var context = ComponentDecodeContext(entityMap: [0: entity])
        for schema in world.componentRegistry.schemas {
            let fields: [String: Any] = schema.typeID == "constraint" ? ["entityA": 0, "entityB": 0] : [:]
            schema.decode(ComponentValue(jsonObject: fields), entity, &context, &world)
            #expect(schema.has(world, entity), "missing decode defaults for \(schema.typeID)")
        }
        #expect(world.component(CameraComponent.self, for: entity)?.isActive == false)
        let emitter = try #require(world.component(ParticleEmitter.self, for: entity))
        #expect(emitter.settings == ParticleEmitter().settings)
        #expect(emitter.aliveCount == 0)
    }

    @Test("v3 JSON matches the pre-registry serializer byte-for-byte, including references")
    func legacyGolden() throws {
        let url = try #require(Bundle.module.url(forResource: "component-registry-v3", withExtension: "json", subdirectory: "Fixtures"))
        let golden = try Data(contentsOf: url)
        var restored = SceneRuntime()
        let created = try SceneSerializer.deserialize(golden, into: &restored)
        #expect(created.count == 2)
        #expect(try SceneSerializer.serialize(restored) == golden)
        let document = try #require(try JSONSerialization.jsonObject(with: golden) as? [String: Any])
        let entities = try #require(document["entities"] as? [[String: Any]])
        let components = try #require(entities.first?["components"] as? [String: Any])
        #expect(Set(components.keys) == Set(restored.componentRegistry.componentSchemas.map(\.typeID)))
    }

    @Test("registrations belong to a scene and survive copying, prefab and game-save paths")
    func sceneLocalRegistration() throws {
        var scene = SceneRuntime()
        let root = scene.createEntity()
        scene.componentRegistry.register(counterSchema)
        _ = scene.setComponent(RegistryCounter(value: 42), for: root)
        #expect(SceneRuntime().componentRegistry["test.counter"] == nil)
        var copied = scene
        #expect(copied.componentRegistry["test.counter"] != nil)
        let prefab = try #require(try Prefab.capture(from: scene, root: root))
        let spawned = try #require(try prefab.instantiate(into: &copied))
        #expect(copied.component(RegistryCounter.self, for: spawned)?.value == 42)
        let save = try GameSave.capture(scene: scene)
        var restored = SceneRuntime(componentRegistry: scene.componentRegistry)
        try save.restoreScene(into: &restored)
        #expect(restored.component(RegistryCounter.self, for: try #require(restored.entities().first))?.value == 42)
    }

    @Test("typed integer component values compare equally after JSON normalization")
    func numericRepresentations() throws {
        for value in [ComponentValue.signedInteger(42), .unsignedInteger(42), .signedInteger(-42),
                      .signedInteger(.max), .unsignedInteger(.max), .number(18_014_398_509_481_984)] {
            #expect(try JSONDecoder().decode(ComponentValue.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(ComponentValue.unsignedInteger(.max) != .number(Double(UInt64.max)))
    }

    @Test("component JSON preserves large integer seeds and booleans through Codable and Foundation")
    func losslessComponentValue() throws {
        let value = ComponentValue(jsonObject: ["seed": UInt64.max, "negative": Int64.min,
                                               "enabled": true, "list": [1.25, 2.5]])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ComponentValue.self, from: data) == value)
        let object = try #require(value.objectValue)
        #expect((object["seed"] as? NSNumber)?.uint64Value == UInt64.max)
        #expect(object["enabled"] as? Bool == true)
    }
}

private struct RegistryCounter: RuntimeComponent { var value: Int }

private let counterSchema = ComponentSchema(RegistryCounter.self, typeID: "test.counter", displayName: "Counter", category: .gameplay,
    encode: { world, entity, context in
        world.component(RegistryCounter.self, for: entity).map { ComponentValue(jsonObject: ["value": $0.value]) }
    }, decode: { value, entity, context, world in
        _ = world.setComponent(RegistryCounter(value: (value.objectValue?["value"] as? NSNumber)?.intValue ?? 0), for: entity)
    }, makeDefault: { entity, world in _ = world.setComponent(RegistryCounter(value: 0), for: entity) })
