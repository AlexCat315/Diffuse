import Foundation
import GuavaUIRuntime
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Script inspector contract", .serialized)
struct ScriptInspectorContractTests {
    private func section(_ adapter: EditorSceneAdapter, _ entity: EntityID) throws -> EditorInspectorSection {
        try #require(adapter.inspectorSections(for: entity.rawValue).first { $0.id == "scripts" })
    }

    @Test("typed fields store only overrides, preserve other keys, support undo and scene roundtrip")
    func propertyEditing() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        _ = adapter.applyProjectScriptCatalog(.builtIn)
        let entity = adapter.scene.createEntity()
        #expect(adapter.addScriptBinding(to: entity.rawValue, identifier: "guava.mover"))
        let original = try section(adapter, entity)
        #expect(original.groups.count == 1)
        #expect(original.fields.first { $0.id == "script-0-parameters" }?.presentation == .advanced)
        guard case let .vector3(x, y, _)? = original.fields.first(where: { $0.id == "script-0-property-velocity" })?.value else {
            Issue.record("Expected typed velocity property"); return
        }
        #expect(x.wrappedValue == 0)
        x.wrappedValue = 3
        y.wrappedValue = 2
        var json = try #require(adapter.scene.component(ScriptComponent.self, for: entity)?.bindings.first?.parametersJSON)
        #expect(ScriptDefinition.decodeParameters(json)["velocity"] as? [Int] == [3, 2, 0])
        #expect(adapter.undoEdit())
        #expect(y.wrappedValue == 0)
        #expect(x.wrappedValue == 3)
        #expect(adapter.redoEdit())
        #expect(y.wrappedValue == 2)
        let manifest = adapter.manifest()
        let restored = EditorSceneAdapter(seedPreviewScene: false)
        _ = restored.applyProjectScriptCatalog(.builtIn)
        _ = restored.load(manifest: try JSONDecoder().decode(EditorSceneManifest.self, from: JSONEncoder().encode(manifest)))
        func bindings(_ nodes: [EditorSceneManifestNode]) -> [ScriptBinding]? {
            nodes.first.flatMap { node in
                sceneDocumentScripts(in: node.components)
            }
        }
        #expect(bindings(try #require(restored.manifest().roots))?.first?.parametersJSON
                == bindings(try #require(adapter.manifest().roots))?.first?.parametersJSON)
        x.wrappedValue = 0
        y.wrappedValue = 0
        json = try #require(adapter.scene.component(ScriptComponent.self, for: entity)?.bindings.first?.parametersJSON)
        #expect(ScriptDefinition.decodeParameters(json).isEmpty)
    }

    @Test("property controls and removal follow binding identity after an earlier binding is removed")
    func stableBindingIdentity() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        _ = adapter.applyProjectScriptCatalog(.builtIn)
        let entity = adapter.scene.createEntity()
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "guava.mover")
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "guava.mover")
        let initial = try section(adapter, entity)
        let secondGroupID = initial.groups[1].id
        guard case let .vector3(firstX, _, _)? = initial.fields.first(where: { $0.id == "script-0-property-velocity" })?.value,
              case let .vector3(secondX, _, _)? = initial.fields.first(where: { $0.id == "script-1-property-velocity" })?.value,
              case let .action(_, _, remove)? = initial.fields.first(where: { $0.id == "script-1-remove" })?.value else {
            Issue.record("Expected two typed behaviors"); return
        }
        _ = adapter.removeScriptBinding(from: entity.rawValue, at: 0)
        firstX.wrappedValue = 99 // A stale control must not edit the remaining binding.
        secondX.wrappedValue = 4
        #expect(try section(adapter, entity).groups.first?.id == secondGroupID)
        let remaining = try #require(adapter.scene.component(ScriptComponent.self, for: entity)?.bindings.first)
        #expect(ScriptDefinition.decodeParameters(remaining.parametersJSON)["velocity"] as? [Int] == [4, 0, 0])
        remove()
        #expect(adapter.scene.component(ScriptComponent.self, for: entity)?.bindings.isEmpty == true)
    }

    @Test("legacy bindings retain the behavior name and source link without duplicating the script picker")
    func legacySourceIdentity() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        adapter.setDynamicScriptOptions(["scripts.asset.player": "Player"], aliases: ["scripts.Player": "scripts.asset.player"])
        let entity = adapter.scene.createEntity()
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "scripts.Player")
        let schema = try section(adapter, entity)
        #expect(schema.groups.first?.title == "Player · Swift")
        #expect(schema.groups.first?.sourceIdentifier == "scripts.asset.player")
        if case let .readOnly(message)? = schema.fields.first(where: { $0.id == "script-0-interface" })?.value {
            #expect(message == L("Build script to load properties"))
        } else { Issue.record("Expected unbuilt script property guidance") }
        #expect(adapter.availableScriptOptions.map(\.value) == ["scripts.asset.player"])
        adapter.unregisterDynamicScriptOption(identifier: "scripts.asset.player")
        #expect(try section(adapter, entity).groups.first?.sourceIdentifier == nil)
    }

    @Test("custom definitions expose choices, project defaults and semantic errors for legacy JSON")
    func customContract() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let definition = ScriptDefinition(properties: [
            ScriptProperty("speed", label: "Speed", group: "Movement", defaultValue: .number(2), minimum: 0, maximum: 10),
            ScriptProperty("mode", label: "Mode", defaultValue: .string("ready"), options: [ScriptPropertyOption("ready"), ScriptPropertyOption("playing")]),
        ])
        adapter.scriptRuntime.register(named: "test.player", defaultParametersJSON: #"{"speed":5}"#, definition: definition) { Script() }
        adapter.registerDynamicScriptOption(identifier: "test.player", displayName: "Player")
        let entity = adapter.scene.createEntity()
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "test.player")
        let schema = try section(adapter, entity)
        #expect(schema.groups.first?.sourceIdentifier == "test.player")
        guard case let .constrainedNumber(speed, _, _, _, _)? = schema.fields.first(where: { $0.id == "script-0-property-speed" })?.value,
              case let .stringOptions(mode, options)? = schema.fields.first(where: { $0.id == "script-0-property-mode" })?.value,
              case let .json(raw, _)? = schema.fields.first(where: { $0.id == "script-0-parameters" })?.value else {
            Issue.record("Expected typed custom script interface"); return
        }
        #expect(speed.wrappedValue == 5)
        #expect(options.count == 2)
        speed.wrappedValue = 11
        #expect(speed.wrappedValue == 5)
        mode.wrappedValue = "playing"
        raw.wrappedValue = #"{"speed":true,"title":"ignored"}"#
        #expect(speed.wrappedValue == 5)
        #expect(try section(adapter, entity).fields.contains { $0.id == "script-0-issues" })
        raw.wrappedValue = "[]"
        #expect(raw.wrappedValue != "[]")
    }
}
