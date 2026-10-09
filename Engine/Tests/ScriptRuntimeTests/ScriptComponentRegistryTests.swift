import Foundation
import SceneRuntime
import ScriptRuntime
import Testing

@Suite("Script component registry codec")
struct ScriptComponentRegistryTests {

    @Test("once registered, base serialization carries script through the components loop")
    func registeredCodecFlowsThroughUniformLoop() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let bindingID = ScriptBindingID()
        _ = scene.setComponent(
            ScriptComponent(ScriptBinding(identifier: "project.native",
                                          id: bindingID,
                                          isEnabled: false,
                                          parametersJSON: #"{"level":3}"#)),
            for: entity
        )

        scene.componentRegistry.registerScriptCodec()
        let codec = try #require(scene.componentRegistry["script"])
        #expect(codec.displayName == "Script")

        let data = try SceneSerializer.serialize(scene)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try #require(json["entities"] as? [[String: Any]])
        let components = try #require(entities.first?["components"] as? [String: Any])
        let script = try #require(components["script"] as? [String: Any])
        let bindings = try #require(script["bindings"] as? [[String: Any]])
        #expect(bindings.count == 1)
        #expect(bindings.first?["bindingID"] as? String == bindingID.uuidString)
        #expect(bindings.first?["identifier"] as? String == "project.native")
        #expect(bindings.first?["isEnabled"] as? Bool == false)
        #expect(bindings.first?["parametersJSON"] as? String == #"{"level":3}"#)

        var restored = SceneRuntime(componentRegistry: scene.componentRegistry)
        _ = try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        let restoredBinding = try #require(
            restored.component(ScriptComponent.self, for: restoredEntity)?.bindings.first
        )
        #expect(restoredBinding.identifier == "project.native")
        #expect(restoredBinding.id == bindingID)
        #expect(restoredBinding.script.rawValue == 0)
    }

    @Test("registered script codec stays part of the registry and keeps identifiers unique")
    func registeredCodecPreservesRegistryInvariants() throws {
        var scene = SceneRuntime()
        scene.componentRegistry.registerScriptCodec()
        let codecs = scene.componentRegistry.schemas
        let scriptCodecs = codecs.filter { $0.typeID == "script" }
        #expect(scriptCodecs.count == 1)
        #expect(Set(codecs.map(\.typeID)).count == codecs.count)
        #expect(!scriptCodecs[0].typeID.isEmpty)
        #expect(!scriptCodecs[0].displayName.isEmpty)
    }

    @Test("script decode defaults to empty bindings and registration is scene-local")
    func defaultsAndIsolation() throws {
        var scene = SceneRuntime()
        scene.componentRegistry.registerScriptCodec()
        #expect(SceneRuntime().componentRegistry["script"] == nil)
        let entity = scene.createEntity()
        var context = ComponentDecodeContext(entityMap: [0: entity])
        SceneSerializer.applyComponentDocument([ManifestComponent(type: "script", value: .object([:]))],
                                               to: entity, in: &scene, context: &context)
        #expect(scene.component(ScriptComponent.self, for: entity)?.bindings == [])
    }

    @Test("prefab capture embeds scripts in the document natively")
    func prefabCarriesScriptBindingsInDocument() throws {
        var scene = SceneRuntime()
        let root = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Root"), for: root)
        _ = scene.setComponent(
            ScriptComponent(ScriptBinding(identifier: "project.template")),
            for: root
        )

        let prefab = try #require(try Prefab.captureFull(from: scene, root: root))
        let json = try #require(try JSONSerialization.jsonObject(with: prefab.data) as? [String: Any])
        let entities = try #require(json["entities"] as? [[String: Any]])
        let components = try #require(entities.first?["components"] as? [String: Any])
        let script = try #require(components["script"] as? [String: Any])
        let bindings = try #require(script["bindings"] as? [[String: Any]])
        #expect(bindings.first?["identifier"] as? String == "project.template")

        var destination = SceneRuntime()
        let newRoot = try #require(try prefab.instantiateFull(into: &destination))
        #expect(
            destination.component(ScriptComponent.self, for: newRoot)?
                .bindings.first?.identifier == "project.template"
        )
    }
}