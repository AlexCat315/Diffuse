import Foundation
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Registry-backed editor documents", .serialized)
struct EditorComponentRegistryTests {
    @Test("a module registration supplies menus, defaults, reset, undo, manifest and prefab persistence")
    func contributedComponent() throws {
        var registry = ComponentRegistry.builtIn
        registry.register(editorCounterSchema)
        let source = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
        let entity = source.scene.createEntity()
        source.resetEditHistory()
        #expect(source.addableComponentSchemas(on: entity.rawValue).contains { $0.typeID == "test.counter" })
        #expect(source.addComponent("test.counter", to: entity.rawValue))
        #expect(source.scene.component(EditorRegistryCounter.self, for: entity)?.value == 7)
        #expect(source.undoEdit())
        #expect(!source.hasComponent("test.counter", on: entity.rawValue))
        #expect(source.redoEdit())
        _ = source.scene.setComponent(EditorRegistryCounter(value: 42), for: entity)
        source.notifyRevisionChanged()

        let manifest = source.manifest(selectedEntityID: entity.rawValue)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        #expect(decoded == manifest)
        let destination = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
        let loaded = destination.load(manifest: decoded)
        #expect(loaded.succeeded)
        let restored = EntityID(rawValue: try #require(loaded.selectedEntityID))
        #expect(destination.scene.component(EditorRegistryCounter.self, for: restored)?.value == 42)
        #expect(destination.resetComponent("test.counter", on: restored.rawValue))
        #expect(destination.scene.component(EditorRegistryCounter.self, for: restored)?.value == 7)
        #expect(destination.undoEdit())
        #expect(destination.scene.component(EditorRegistryCounter.self, for: restored)?.value == 42)
        #expect(destination.removeComponent("test.counter", from: restored.rawValue))
        #expect(destination.undoEdit())
        #expect(destination.hasComponent("test.counter", on: restored.rawValue))

        let prefab = try #require(try Prefab.capture(from: destination.scene, root: restored))
        let instance = try #require(try prefab.instantiate(into: &destination.scene))
        #expect(destination.scene.component(EditorRegistryCounter.self, for: instance)?.value == 42)
        destination.resetToPreviewScene()
        #expect(destination.scene.componentRegistry["test.counter"] != nil)
        #expect(EditorSceneAdapter(seedPreviewScene: false).scene.componentRegistry["test.counter"] == nil)
    }

    @Test("manifest and prefab use the same component values and remap forward references")
    func prefabInteroperation() throws {
        let source = EditorSceneAdapter(seedPreviewScene: false)
        let root = source.scene.createEntity()
        let child = source.scene.createEntity()
        _ = source.scene.setLocalTransform(.identity, for: root)
        _ = source.scene.setLocalTransform(LocalTransform(translation: SIMD3(1, 2, 3)), for: child)
        _ = source.scene.setParent(root, for: child)
        _ = source.scene.setComponent(Constraint(constraintType: .hinge, entityA: root, entityB: child), for: root)
        _ = source.scene.setComponent(Ragdoll(bones: [RagdollBoneMapping(boneName: "Hip", paletteIndex: 0,
                                                                        bodyEntity: child, jointEntity: root)]), for: root)
        _ = source.scene.setComponent(ScriptComponent(ScriptBinding(identifier: "project.test")), for: child)
        let manifest = source.manifest()
        let prefab = try #require(try Prefab.capture(from: source.scene, root: root))
        let document = try #require(try JSONSerialization.jsonObject(with: prefab.data) as? [String: Any])
        let records = try #require(document["entities"] as? [[String: Any]])
        for (node, record) in zip([manifest.roots[0], manifest.roots[0].children[0]], records) {
            let runtimeValues = try #require(record["components"] as? [String: Any])
            #expect(ComponentValue(jsonObject: runtimeValues) == .object(Dictionary(uniqueKeysWithValues:
                node.components.map { ($0.type, $0.value) })))
        }
        var occupied = SceneRuntime(componentRegistry: source.scene.componentRegistry)
        _ = occupied.createEntity()
        let instance = try #require(try prefab.instantiate(into: &occupied))
        let instanceChild = try #require(occupied.children(of: instance).first)
        #expect(occupied.component(Constraint.self, for: instance)?.entityB == instanceChild)
        #expect(occupied.component(Ragdoll.self, for: instance)?.bones.first?.jointEntity == instance)
        #expect(occupied.component(ScriptComponent.self, for: instanceChild)?.bindings.first?.identifier == "project.test")

        let restored = EditorSceneAdapter(seedPreviewScene: false)
        #expect(restored.load(manifest: manifest).succeeded)
        let restoredRoot = try #require(restored.scene.roots().first)
        let restoredChild = try #require(restored.scene.children(of: restoredRoot).first)
        #expect(restored.scene.component(Constraint.self, for: restoredRoot)?.entityB == restoredChild)
        #expect(restored.scene.component(Ragdoll.self, for: restoredRoot)?.bones.first?.bodyEntity == restoredChild)
    }
}

private struct EditorRegistryCounter: RuntimeComponent { var value: Int }

private let editorCounterSchema = ComponentSchema(EditorRegistryCounter.self,
    typeID: "test.counter", displayName: "Counter", category: .gameplay,
    encode: { world, entity, context in
        world.component(EditorRegistryCounter.self, for: entity).map { ComponentValue(jsonObject: ["value": $0.value]) }
    }, decode: { value, entity, context, world in
        _ = world.setComponent(EditorRegistryCounter(value: (value.objectValue?["value"] as? NSNumber)?.intValue ?? 7), for: entity)
    }, makeDefault: { entity, world in _ = world.setComponent(EditorRegistryCounter(value: 7), for: entity) })

extension EditorComponentRegistryTests {
    @Test("camera and light templates use registry defaults and undo as one creation")
    func registryTemplateDefaults() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let defaults = adapter.scene.createEntity()
        try adapter.scene.addComponent(typeID: "camera", for: defaults)
        try adapter.scene.addComponent(typeID: "light", for: defaults)
        let cameraDefault = try #require(adapter.scene.component(CameraComponent.self, for: defaults))
        let lightDefault = try #require(adapter.scene.component(LightComponent.self, for: defaults))
        adapter.resetEditHistory()
        for (template, type) in [(EditorEntityTemplate.directionalLight, LightType.directional),
                                 (.pointLight, .point), (.spotLight, .spot)] {
            let id = try #require(adapter.spawnEntity(template: template, at: SIMD3(2, 3, 4)))
            let entity = EntityID(rawValue: id)
            var expected = lightDefault
            expected.type = type
            #expect(adapter.scene.component(LightComponent.self, for: entity) == expected)
            #expect(adapter.scene.component(LocalTransform.self, for: entity)?.translation == SIMD3(2, 3, 4))
            #expect(adapter.undoEdit())
            #expect(!adapter.scene.contains(entity))
            #expect(!adapter.canUndoEdit)
            #expect(adapter.redoEdit())
            #expect(adapter.scene.component(LightComponent.self, for: entity) == expected)
            adapter.resetEditHistory()
        }
        let cameraID = try #require(adapter.spawnEntity(template: .camera))
        #expect(adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: cameraID)) == cameraDefault)
        #expect(adapter.undoEdit())
        #expect(!adapter.scene.contains(EntityID(rawValue: cameraID)))
    }

    @Test("templates honor contributed defaults and manifest loading supplies omitted dependencies")
    func contributedTemplateDefaults() throws {
        let builtin = ComponentRegistry.builtIn
        let camera = try #require(builtin["camera"])
        var registry = ComponentRegistry()
        for schema in builtin.schemas where schema.typeID != "camera" { registry.register(schema) }
        registry.register(ComponentSchema(CameraComponent.self, typeID: "camera", displayName: "Camera", category: .rendering,
            encode: camera.encode, decode: camera.decode,
            makeDefault: { entity, world in
                _ = world.setComponent(CameraComponent(fovYRadians: 0.7, near: 0.25, far: 250, isActive: false), for: entity)
            }, configure: { $0.requires = ["localTransform"] }))
        let adapter = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
        let id = try #require(adapter.spawnEntity(template: .camera))
        #expect(adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id))?.fovYRadians == 0.7)
        let node = try #require(adapter.manifest().roots.first)
        #expect(!node.components.contains { $0.type == "localTransform" })
        let withoutTransform = EditorSceneManifestNode(id: node.id, name: node.name, kind: node.kind,
                                                       components: node.components)
        let manifest = EditorSceneManifest(revision: 0, entityCount: 1, roots: [withoutTransform])
        let restored = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
        #expect(restored.load(manifest: manifest).succeeded)
        let entity = try #require(restored.scene.entities().first)
        #expect(restored.scene.component(LocalTransform.self, for: entity) == .identity)
        #expect(restored.scene.component(CameraComponent.self, for: entity)?.fovYRadians == 0.7)
    }

    @Test("interactive component edits coalesce by entity and component type")
    func interactiveComponentIdentity() throws {
        var registry = ComponentRegistry.builtIn
        registry.register(editorCounterSchema)
        let adapter = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
        let first = adapter.scene.createEntity()
        let second = adapter.scene.createEntity()
        #expect(adapter.addComponent("test.counter", to: [first.rawValue, second.rawValue]))
        #expect(adapter.addComponent("light", to: first.rawValue))
        adapter.resetEditHistory()

        adapter.beginInteractiveEditHistoryGroup()
        #expect(adapter.updateComponentData(EditorRegistryCounter.self, for: first) { $0.value = 8 })
        #expect(adapter.updateComponentData(EditorRegistryCounter.self, for: first) { $0.value = 9 })
        #expect(!adapter.canUndoEdit)
        #expect(adapter.updateComponentData(EditorRegistryCounter.self, for: second) { $0.value = 11 })
        #expect(adapter.updateComponentData(LightComponent.self, for: first) { $0.intensity = 10 })
        adapter.endInteractiveEditHistoryGroup()

        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(LightComponent.self, for: first)?.intensity == 1)
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: second)?.value == 11)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: second)?.value == 7)
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: first)?.value == 9)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: first)?.value == 7)
        #expect(!adapter.canUndoEdit)
        #expect(adapter.redoEdit())
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: first)?.value == 9)
        #expect(adapter.redoEdit())
        #expect(adapter.redoEdit())
        #expect(adapter.scene.component(LightComponent.self, for: first)?.intensity == 10)
    }

    @Test("contributed edits cancel cleanly and a new edit invalidates redo")
    func contributedEditCancellation() throws {
        var registry = ComponentRegistry.builtIn
        registry.register(editorCounterSchema)
        let adapter = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("test.counter", to: entity.rawValue))
        adapter.resetEditHistory()
        adapter.beginInteractiveEditHistoryGroup()
        #expect(adapter.updateComponentData(EditorRegistryCounter.self, for: entity) { $0.value = 21 })
        adapter.cancelInteractiveEditHistoryGroup()
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: entity)?.value == 7)
        #expect(!adapter.canUndoEdit)
        #expect(adapter.updateComponentData(EditorRegistryCounter.self, for: entity) { $0.value = 30 })
        #expect(adapter.undoEdit())
        #expect(adapter.canRedoEdit)
        #expect(adapter.updateComponentData(EditorRegistryCounter.self, for: entity) { $0.value = 40 })
        #expect(!adapter.canRedoEdit)
        adapter.setEntityLocked(true, entityIDs: [entity.rawValue])
        #expect(!adapter.updateComponentData(EditorRegistryCounter.self, for: entity) { $0.value = 50 })
        #expect(adapter.scene.component(EditorRegistryCounter.self, for: entity)?.value == 40)
    }
}
