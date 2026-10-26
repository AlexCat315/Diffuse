@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import SceneRuntime
import ScriptRuntime
import Testing
@testable import EditorUI

@Suite("Script behavior inspector", .serialized)
@MainActor
struct ScriptBehaviorInspectorTests {
    @Test("behavior headers fit narrow panels, open their source and toggle without collapsing",
          arguments: [Float(260), Float(320)])
    func headerInteractions(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { registry, _ in
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let definition = ScriptDefinition(properties: [ScriptProperty("speed", label: "Move Speed", defaultValue: .number(4.5))])
        adapter.scriptRuntime.register(named: "scripts.test", definition: definition) { Script() }
        adapter.registerDynamicScriptOption(identifier: "scripts.test", displayName: "CrystalRush")
        let entity = adapter.scene.createEntity()
        #expect(adapter.addScriptBinding(to: entity.rawValue, identifier: "scripts.test"))
        let section = try #require(adapter.inspectorSections(for: entity.rawValue).first { $0.id == "scripts" })
        let group = try #require(section.groups.first)
        let store = EditorStore()
        store.dispatch(.setSelectedEntity(entity.rawValue))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: InspectorPanel(store: store, scene: adapter, sectionFilter: ["scripts"],
                                          onOpenScript: { _ in })
            .theme(EditorVisualTheme.make(dark: false)))
        graph.computeLayout(width: width, height: 560)
        var frames = graph.layoutSnapshot()
        #expect(!frames.contains { $0.debugName?.hasPrefix("inspector-json-") == true })
        // One row: title, then status, the on/off switch and the menu (which
        // also opens the source) at the trailing edge.
        let menu = try #require(frames.first { $0.debugName == "inspector-script-menu-\(group.id)" }?.absoluteFrame)
        let enabled = try #require(frames.first { $0.debugName == "inspector-script-enabled-\(group.id)" }?.absoluteFrame)
        let header = try #require(frames.first { $0.debugName == "property-section-header-\(group.id)" }?.absoluteFrame)
        #expect(menu.maxX <= CGFloat(width))
        #expect(header.maxX <= enabled.minX)
        #expect(enabled.maxX <= menu.minX)
        #expect(store.inspectorCollapsedSectionIDs.isEmpty)
        try WorkbenchUITestSupport.activate("inspector-script-enabled-\(group.id)", in: tree.root, registry: registry)
        #expect(adapter.scene.component(ScriptComponent.self, for: entity)?.bindings.first?.isEnabled == false)
        #expect(store.inspectorCollapsedSectionIDs.isEmpty)
        try WorkbenchUITestSupport.activate("property-section-header-\(group.id)", in: tree.root, registry: registry)
        graph.recomposer.commitAll()
        AnimatorScheduler.current.tick(deltaTime: 1)
        graph.recomposer.commitAll()
        graph.computeLayout(width: width, height: 560)
        frames = graph.layoutSnapshot()
        #expect(store.inspectorCollapsedSectionIDs.contains(group.id))
        #expect(!frames.contains { $0.debugName?.hasPrefix("inspector-advanced-\(group.id)") == true })
    } }

    @Test("search retains behavior identity and controls while filtering the property form")
    func searchGroups() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        _ = adapter.applyProjectScriptCatalog(.builtIn)
        let entity = adapter.scene.createEntity()
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "cove.mover")
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "cove.rotator")
        let section = try #require(adapter.inspectorSections(for: entity.rawValue).first { $0.id == "scripts" })
        // Search by the behavior name: it is unique per binding in every UI language.
        let query = try #require(section.groups.first).title
        let filtered = try #require(InspectorSectionFilter.filter([section], query: query).first)
        #expect(filtered.groups.count == 1)
        #expect(filtered.groups.first?.id == section.groups.first?.id)
        #expect(filtered.fields.contains { $0.id == "script-0-enabled" })
        #expect(filtered.fields.contains { $0.id == "script-0-remove" })
        #expect(!filtered.fields.contains { $0.id == "script-1-property-speed" })
    }

    @Test("unbuilt property guidance fits the behavior body while advanced JSON stays folded",
          arguments: [Float(260), Float(320)])
    func unbuiltGuidance(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        adapter.registerDynamicScriptOption(identifier: "scripts.test", displayName: "CrystalRush")
        let entity = adapter.scene.createEntity()
        _ = adapter.addScriptBinding(to: entity.rawValue, identifier: "scripts.test")
        let group = try #require(adapter.inspectorSections(for: entity.rawValue).first { $0.id == "scripts" }?.groups.first)
        let store = EditorStore()
        store.dispatch(.setSelectedEntity(entity.rawValue))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: InspectorPanel(store: store, scene: adapter, sectionFilter: ["scripts"])
            .theme(EditorVisualTheme.make(dark: false)))
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 560) }
        let frames = graph.layoutSnapshot()
        let message = try #require(frames.first { $0.debugName?.hasPrefix("inspector-script-message-\(group.id)/") == true }?.absoluteFrame)
        #expect(message.width > 150)
        #expect(message.maxX <= CGFloat(width))
        #expect(message.height > 0)
        #expect(!frames.contains { $0.debugName?.hasPrefix("inspector-json-") == true })
    } }
}
