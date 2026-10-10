import Foundation
import Testing
@testable import SceneRuntime

@Suite("Component declarations")
struct ComponentDeclarationTests {
    private func makeDescription(typeID: String = "plugin.weather",
                                 defaults: ComponentValue? = .object(["intensity": .number(0.5)])) -> ComponentDescription {
        ComponentDescription(
            typeID: typeID,
            displayName: "Weather Zone",
            category: .gameplay,
            requires: [],
            isUserAddable: true,
            fields: [ComponentFieldDescriptor(["intensity"]) { $0.kind = .number }],
            defaults: defaults)
    }

    @Test("declared components store, edit, duplicate and describe through the registry")
    func declaredComponentLifecycle() throws {
        let payload = try JSONEncoder().encode([makeDescription()])
        var registry = ComponentRegistry.builtIn
        try registry.register(contentsOf: ComponentDeclarations.decode(payload))
        #expect(registry["plugin.weather"]?.displayName == "Weather Zone")

        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        try scene.addComponent(typeID: "plugin.weather", for: entity)
        #expect(scene.hasComponent(typeID: "plugin.weather", for: entity))
        #expect(scene.componentData("plugin.weather", for: entity) == .object(["intensity": .number(0.5)]))

        try scene.setComponentData(.object(["intensity": .number(0.8)]), typeID: "plugin.weather",
                                   for: entity, mode: .merge)
        #expect(scene.componentData("plugin.weather", for: entity) == .object(["intensity": .number(0.8)]))

        let copy = scene.createEntity()
        scene.duplicateComponentData(from: entity, to: copy)
        #expect(scene.componentData("plugin.weather", for: copy) == .object(["intensity": .number(0.8)]))

        let description = try #require(scene.componentDescriptions(typeID: "plugin.weather").first)
        #expect(description.displayName == "Weather Zone")
        #expect(description.fields.contains { $0.id == "intensity" })
        #expect(description.defaults == .object(["intensity": .number(0.5)]))

        try scene.removeComponentData(typeID: "plugin.weather", for: entity)
        #expect(!scene.hasComponent(typeID: "plugin.weather", for: entity))
        #expect(scene.componentData("plugin.weather", for: copy) != nil)
    }

    @Test("destroying an entity drops its declared documents")
    func declaredDocumentsFollowEntities() throws {
        let payload = try JSONEncoder().encode([makeDescription()])
        var registry = ComponentRegistry.builtIn
        try registry.register(contentsOf: ComponentDeclarations.decode(payload))
        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        try scene.addComponent(typeID: "plugin.weather", for: entity)
        _ = scene.destroyEntity(entity)
        #expect(scene.componentData("plugin.weather", for: entity) == nil)
    }

    @Test("untrusted declarations are rejected instead of trapping")
    func declarationValidation() throws {
        let registry = ComponentRegistry.builtIn
        #expect(throws: ComponentDeclarationError.unnamespacedTypeID("collider")) {
            _ = try ComponentDeclarations.decode(try JSONEncoder().encode([makeDescription(typeID: "collider")]))
        }
        #expect(throws: ComponentDeclarationError.missingDefaults("plugin.weather")) {
            _ = try ComponentDeclarations.decode(try JSONEncoder().encode([makeDescription(defaults: nil)]))
        }
        var tightLimits = ComponentDeclarationLimits()
        tightLimits.maximumComponents = 1
        #expect(throws: ComponentDeclarationError.tooManyComponents(2)) {
            _ = try ComponentDeclarations.decode(
                try JSONEncoder().encode([makeDescription(), makeDescription(typeID: "plugin.other")]),
                limits: tightLimits)
        }
        #expect(throws: ComponentDeclarationError.invalidPayload) {
            _ = try ComponentDeclarations.decode(Data("{}".utf8))
        }
        var installing = registry
        try installing.register(contentsOf: ComponentDeclarations.decode(
            try JSONEncoder().encode([makeDescription()])))
        #expect(throws: ComponentDeclarationError.duplicateTypeID("plugin.weather")) {
            try installing.register(contentsOf: ComponentDeclarations.decode(
                try JSONEncoder().encode([makeDescription()])))
        }
    }

    @Test("built-in schemas keep working alongside declared ones")
    func builtInsAreUnaffected() throws {
        let payload = try JSONEncoder().encode([makeDescription()])
        var registry = ComponentRegistry.builtIn
        try registry.register(contentsOf: ComponentDeclarations.decode(payload))
        try registry.validateRequirements()
        #expect(registry["collider"] != nil)
        #expect(registry.componentSchemas.count > registry.componentSchemas.filter({ $0.typeID == "plugin.weather" }).count)
    }
}
