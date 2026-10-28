import AssetPipeline
@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import Testing
@testable import EditorUI

@Suite("DCC geometry inspector", .serialized)
@MainActor
struct GeometryInspectorLayoutTests {
    @Test("modifier buttons update the live inspector and source file", arguments: [Float(280),Float(360)])
    func modifierWorkflow(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dcc-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        let id = try #require(app.geometryAuthoring.create(.box))
        let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
        graph.install(root: InspectorPanel(store: app.store,scene: app.scene).theme(EditorVisualTheme.make(dark: false)))
        graph.computeLayout(width: width,height: 800)
        try WorkbenchUITestSupport.activate("inspector-field-geometry-modifiers/geometry-add-subdivision",in: graph.tree.root,registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: width,height: 800)
        let document = try #require(try app.geometryAuthoring.document(for: id))
        let modifierID = try #require(document.modifiers.first?.id)
        _ = try WorkbenchUITestSupport.named("property-section-header-geometry-modifier-\(modifierID)",in: graph.tree.root)
        let levels = try WorkbenchUITestSupport.named("inspector-field-geometry-modifier-\(modifierID)/\(modifierID)-levels",in: graph.tree.root)
        let input = try #require(WorkbenchUITestSupport.firstNode(levels) { registry.handlers(for: $0).text != nil })
        focus.focus(input)
        graph.recomposer.commitAll()
        let handlers = registry.handlers(for: input)
        _ = handlers.key?(KeyEvent(scancode: 4,keycode: 0,modifiers: [.lgui],isRepeat: false),.target)
        _ = handlers.text?("2",.target)
        _ = handlers.key?(KeyEvent(scancode: 40,keycode: 0,modifiers: [],isRepeat: false),.target)
        focus.clear()
        graph.recomposer.commitAll()
        #expect(try app.geometryAuthoring.document(for: id)?.modifiers[0].operation == .subdivision(levels: 2))
        try WorkbenchUITestSupport.activate("inspector-field-geometry-modifier-\(modifierID)/\(modifierID)-remove",in: graph.tree.root,registry: registry)
        graph.recomposer.commitAll()
        graph.computeLayout(width: width,height: 800)
        #expect(try app.geometryAuthoring.document(for: id)?.modifiers.isEmpty == true)
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "property-section-header-geometry-modifier-\(modifierID)" })
        app.undo()
        graph.recomposer.commitAll()
        graph.computeLayout(width: width,height: 800)
        _ = try WorkbenchUITestSupport.named("property-section-header-geometry-modifier-\(modifierID)",in: graph.tree.root)
        let draw = DrawList()
        NodeRenderer().render(root: try #require(graph.tree.root),into: draw)
        for entry in graph.layoutSnapshot() where entry.debugName?.hasPrefix("property-section-header-geometry") == true {
            #expect(entry.absoluteFrame.minX >= 0)
            #expect(entry.absoluteFrame.maxX <= CGFloat(width))
        }
    } }
}
