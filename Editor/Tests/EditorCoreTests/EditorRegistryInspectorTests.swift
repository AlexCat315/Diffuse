@testable import EditorCore
import Foundation
import GuavaUIRuntime
import SceneRuntime
import Testing

@Suite("Registry inspector", .serialized)
struct EditorRegistryInspectorTests {
    private func adapter() -> EditorSceneAdapter {
        var registry = ComponentRegistry.builtIn
        registry.register(probeSchema)
        return EditorSceneAdapter(seedPreviewScene: false, componentRegistry: registry)
    }

    private func field(_ adapter: EditorSceneAdapter, _ ids: Set<UInt64>, _ path: String) throws -> EditorInspectorField {
        try #require(adapter.inspectorSections(for: ids).first { $0.id == "test.probe" }?
            .fields.first { $0.id == path })
    }

    @Test("a contributed schema gets a form, nested transactions and exact integer editing without UI registration")
    func contributedForm() throws {
        let adapter = adapter()
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("test.probe", to: entity.rawValue))
        adapter.resetEditHistory()
        let descriptions = adapter.scene.componentDescriptions(typeID: "test.probe")
        #expect(descriptions.first?.fields.map(\.id).contains("settings.gain") == true)
        guard case let .constrainedNumber(gain, min, max, _, _) = try field(adapter, [entity.rawValue], "settings.gain").value,
              case let .text(seed) = try field(adapter, [entity.rawValue], "seed").value else {
            Issue.record("Expected registry bindings"); return
        }
        #expect(min == 0 && max == 5)
        #expect(seed.wrappedValue == String(UInt64.max))
        gain.wrappedValue = 12
        #expect(adapter.scene.component(InspectorProbe.self, for: entity)?.settings.gain == 5)
        #expect(adapter.scene.component(InspectorProbe.self, for: entity)?.settings.enabled == true)
        #expect(adapter.scene.component(InspectorProbe.self, for: entity)?.seed == .max)
        #expect(adapter.undoEdit())
        #expect(gain.wrappedValue == 1)
        #expect(adapter.redoEdit())
        seed.wrappedValue = "18446744073709551614"
        #expect(adapter.scene.component(InspectorProbe.self, for: entity)?.seed == UInt64.max - 1)
        #expect(adapter.undoEdit())
        #expect(seed.wrappedValue == String(UInt64.max))
    }

    @Test("inferred vector axes preserve each selection's remaining coordinates and undo as one edit")
    func multiSelectionVector() throws {
        let adapter = adapter()
        let a = adapter.scene.createEntity(), b = adapter.scene.createEntity()
        #expect(adapter.addComponent("test.probe", to: [a.rawValue, b.rawValue]))
        _ = adapter.scene.updateComponent(InspectorProbe.self, for: b) { $0.offset = [4, 8, 16] }
        adapter.resetEditHistory()
        let field = try field(adapter, [a.rawValue, b.rawValue], "offset")
        #expect(adapter.inspectorSections(for: [a.rawValue, b.rawValue]).first { $0.id == "test.probe" }?
            .componentTypeID == "test.probe")
        #expect(field.isMixed && field.mixedAxes == ["x", "y", "z"])
        guard case let .vector3(x, _, _) = field.value else { Issue.record("Expected vector"); return }
        x.wrappedValue = 25
        #expect(adapter.scene.component(InspectorProbe.self, for: a)?.offset == [25, 2, 3])
        #expect(adapter.scene.component(InspectorProbe.self, for: b)?.offset == [25, 8, 16])
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(InspectorProbe.self, for: a)?.offset == [1, 2, 3])
        #expect(adapter.scene.component(InspectorProbe.self, for: b)?.offset == [4, 8, 16])
        #expect(!adapter.canUndoEdit)
    }

    @Test("stale and locked generic bindings reject whole selections")
    func staleAndLockedBindings() throws {
        let adapter = adapter()
        let a = adapter.scene.createEntity(), b = adapter.scene.createEntity()
        #expect(adapter.addComponent("test.probe", to: [a.rawValue, b.rawValue]))
        guard case let .bool(enabled) = try field(adapter, [a.rawValue, b.rawValue], "settings.enabled").value else {
            Issue.record("Expected bool"); return
        }
        adapter.setEntityLocked(true, entityIDs: [b.rawValue])
        let revision = adapter.revision
        enabled.wrappedValue = false
        #expect(adapter.revision == revision)
        #expect(adapter.scene.component(InspectorProbe.self, for: a)?.settings.enabled == true)
        adapter.setEntityLocked(false, entityIDs: [b.rawValue])
        #expect(adapter.removeComponent("test.probe", from: b.rawValue))
        let removedRevision = adapter.revision
        enabled.wrappedValue = false
        #expect(adapter.revision == removedRevision)
        #expect(adapter.scene.component(InspectorProbe.self, for: a)?.settings.enabled == true)
    }

    @Test("options, invalid JSON, read-only fields and interactive cancellation retain authored values")
    func validationAndCancellation() throws {
        let adapter = adapter()
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("test.probe", to: entity.rawValue))
        adapter.resetEditHistory()
        guard case let .stringOptions(mode, _) = try field(adapter, [entity.rawValue], "settings.mode").value,
              case let .json(items, _) = try field(adapter, [entity.rawValue], "items").value,
              case .readOnly = try field(adapter, [entity.rawValue], "source").value else {
            Issue.record("Expected generic controls"); return
        }
        mode.wrappedValue = "unsupported"
        items.wrappedValue = "{invalid"
        items.wrappedValue = "[false]" // The typed codec rejects the wrong element type.
        #expect(!adapter.canUndoEdit)
        #expect(adapter.scene.component(InspectorProbe.self, for: entity) == InspectorProbe())
        adapter.beginInteractiveEditHistoryGroup()
        mode.wrappedValue = "fast"
        items.wrappedValue = "[2, 4]"
        adapter.cancelInteractiveEditHistoryGroup()
        #expect(adapter.scene.component(InspectorProbe.self, for: entity) == InspectorProbe())
        #expect(!adapter.canUndoEdit)
    }

    @Test("a module renderer joins multi-selection and undo using the schema's component identity")
    func contributedRenderer() throws {
        let adapter = adapter()
        try adapter.inspectorRenderers.register(componentTypeID: "test.probe") { adapter, entity in
            guard let form = adapter.registryInspectorSection(probeSchema, for: entity) else { return nil }
            var section = EditorInspectorSection(id: "module-form", title: "Module Form", fields: form.fields)
            section.componentTypeID = "incorrect-renderer-identity"
            return section
        }
        let a = adapter.scene.createEntity(), b = adapter.scene.createEntity()
        #expect(!adapter.inspectorSections(for: a.rawValue).contains { $0.id == "module-form" })
        #expect(adapter.addComponent("test.probe", to: [a.rawValue, b.rawValue]))
        _ = adapter.scene.updateComponent(InspectorProbe.self, for: b) { $0.settings.gain = 2 }
        adapter.resetEditHistory()
        let before = adapter.manifest()
        let section = try #require(adapter.inspectorSections(for: [a.rawValue, b.rawValue]).first {
            $0.id == "module-form"
        })
        #expect(section.componentTypeID == "test.probe")
        #expect(adapter.manifest() == before)
        let field = try #require(section.fields.first { $0.id == "settings.gain" })
        #expect(field.isMixed)
        guard case let .constrainedNumber(gain, _, _, _, _) = field.value else {
            Issue.record("Expected module-rendered binding"); return
        }
        gain.wrappedValue = 4
        #expect(adapter.scene.component(InspectorProbe.self, for: a)?.settings.gain == 4)
        #expect(adapter.scene.component(InspectorProbe.self, for: b)?.settings.gain == 4)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(InspectorProbe.self, for: a)?.settings.gain == 1)
        #expect(adapter.scene.component(InspectorProbe.self, for: b)?.settings.gain == 2)
        #expect(!adapter.canUndoEdit)
        #expect(adapter.redoEdit())
        #expect(adapter.scene.component(InspectorProbe.self, for: b)?.settings.gain == 4)
    }
}

private struct ProbeSettings: Codable, Equatable, Sendable {
    var gain: Float = 1
    var enabled = true
    var mode = "normal"
}

private struct InspectorProbe: RuntimeComponent, Codable, Equatable {
    var settings = ProbeSettings()
    var offset: [Float] = [1, 2, 3]
    var seed: UInt64 = .max
    var items: [Int] = []
    var source = "module"
}

private let probeSchema = ComponentSchema(InspectorProbe.self,
    typeID: "test.probe", displayName: "Probe", category: .gameplay,
    encode: { world, entity, _ in
        guard let component = world.component(InspectorProbe.self, for: entity),
              let data = try? JSONEncoder().encode(component) else { return nil }
        return try? JSONDecoder().decode(ComponentValue.self, from: data)
    }, decode: { value, entity, _, world in
        guard let data = try? JSONEncoder().encode(value),
              let component = try? JSONDecoder().decode(InspectorProbe.self, from: data) else { return }
        _ = world.setComponent(component, for: entity)
    }, makeDefault: { entity, world in _ = world.setComponent(InspectorProbe(), for: entity) },
    configure: { schema in
        schema.inspection.fields = [
            ComponentFieldDescriptor(["settings", "gain"]) { $0.numeric.minimum = 0; $0.numeric.maximum = 5 },
            ComponentFieldDescriptor(["settings", "mode"]) {
                $0.kind = .options; $0.choices = ["normal", "fast"].map { ComponentFieldChoice($0) }
            },
            ComponentFieldDescriptor(["source"]) { $0.isReadOnly = true },
        ]
    })
