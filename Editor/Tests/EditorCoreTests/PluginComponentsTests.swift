import PluginRuntime
import Testing
@testable import EditorCore
@testable import SceneRuntime

@Suite("Plugin component declarations")
struct PluginComponentTests {
    private func weatherDescription() -> ComponentDescription {
        ComponentDescription(
            typeID: "plugin.weather",
            displayName: "Weather Zone",
            category: .gameplay,
            requires: [],
            isUserAddable: true,
            fields: [ComponentFieldDescriptor(["intensity"]) { $0.kind = .number }],
            defaults: .object(["intensity": .number(0.5)]))
    }

    @Test("a declared component reaches the add menu, generated form and AI schema")
    func declaredComponentEndToEnd() throws {
        let store = PluginComponentStore()
        store.set([weatherDescription()], pluginID: "test.plugin")
        let adapter = EditorSceneAdapter(seedPreviewScene: false, componentRegistry: store.registry())
        #expect(adapter.scene.componentRegistry["plugin.weather"] != nil)

        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("plugin.weather", to: entity.rawValue))
        let section = try #require(adapter.inspectorSections(for: entity.rawValue).first {
            $0.componentTypeID == "plugin.weather"
        })
        #expect(section.fields.contains { $0.id == "intensity" })

        let described = adapter.scene.componentDescriptions(typeID: "plugin.weather")
        #expect(described.count == 1)
        #expect(described.first?.displayName == "Weather Zone")
        #expect(described.first?.fields.contains { $0.id == "intensity" } == true)
    }

    @Test("withdrawing a plugin removes its component from registries built afterwards")
    func withdrawal() throws {
        let store = PluginComponentStore()
        store.set([weatherDescription()], pluginID: "test.plugin")
        #expect(store.registry()["plugin.weather"] != nil)
        store.remove(pluginID: "test.plugin")
        #expect(store.isEmpty)
        #expect(store.registry()["plugin.weather"] == nil)
        #expect(store.registry()["collider"] != nil)
    }

    @Test("the reserved capability is namespaced by plugin ID")
    func reservedCapability() {
        #expect(PluginComponentCapability.capabilityID(pluginID: "acme.weather") == "acme.weather.components")
        #expect(PluginComponentCapability.name == "components")
    }
}
