@testable import EditorCore
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import Testing
@testable import EditorApp

@Suite("Inspector search regressions", .serialized)
struct InspectorSearchRegressionTests {
    @Test("the themed script surface fills its viewport and leaves the footer at the bottom")
    func scriptViewport() throws { try WorkbenchUITestSupport.withEnvironment { registry, _ in
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ScriptCodeEditor(source: .constant("let value = 1"), hover: .constant(.hidden),
                                             caretLabel: .constant("Ln 1, Col 1"), onChange: { _ in },
                                             onHover: { _ in }, onHoverEnd: {})
            .theme(EditorVisualTheme.make(dark: false))
            .flex(1, shrink: 1).frame(width: 600, height: 400))
        graph.computeLayout(width: 600, height: 400)
        let field = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
            registry.handlers(for: $0).text != nil
        })
        #expect(field.frame.height > 350)
        #expect(field.absoluteFrame.maxY >= 370)
    } }
    @Test("typing and clearing search survives filtered teardown and restores the focused field")
    func liveSearch() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        var scene = EditorSceneAdapter()
        let entity = scene.scene.createEntity()
        #expect(scene.addComponent("rigidbody", to: entity.rawValue))
        #expect(scene.addComponent("collider", to: entity.rawValue))
        let store = EditorStore()
        store.dispatch(.setSelectedEntity(entity.rawValue))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: InspectorPanel(store: store, scene: scene)
            .theme(EditorVisualTheme.make(dark: false)))
        graph.computeLayout(width: 330, height: 800)
        let field = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
            registry.handlers(for: $0).text != nil
        })
        focus.focus(field)
        graph.recomposer.commitAll()
        for query in ["mass", "no such property", "质量", "", "transform", ""] {
            let handlers = registry.handlers(for: field)
            _ = handlers.key?(KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
            _ = handlers.key?(KeyEvent(scancode: Scancode.backspace, keycode: 0, modifiers: [], isRepeat: false), .target)
            _ = handlers.text?(query, .target)
            graph.recomposer.commitAll()
            AnimatorScheduler.current.tick(deltaTime: 1)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 330, height: 800)
            let draw = DrawList()
            NodeRenderer().render(root: try #require(graph.tree.root), into: draw)
            #expect(focus.focused === field)
            #expect(registry.handlers(for: field).text != nil)
        }
    } }
}
