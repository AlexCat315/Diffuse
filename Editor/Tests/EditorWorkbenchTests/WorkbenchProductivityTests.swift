@testable import EditorApp
import EditorCore
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Testing

@Suite("Workbench productivity interactions", .serialized)
struct WorkbenchProductivityTests {
    @Test("the animation panel edits only animation fields and accepts a legacy primary selection")
    func animationPanel() throws { try WorkbenchUITestSupport.withEnvironment { registry, _ in
        let scene = EditorSceneAdapter(seedPreviewScene: false)
        let entity = try #require(scene.spawnEntity(template: .pointLight))
        #expect(scene.addComponent(.animationPlayer, to: entity))
        let store = EditorStore(state: EditorState {
            $0.selection.selectedEntityID = entity
        })
        store.dispatch(.setInspectorSceneSettingsVisible(true))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: InspectorPanel(store: store, scene: scene,
                                         sectionFilter: ["animation-player", "animation-graph-player"]))
        graph.computeLayout(width: 330, height: 480)
        func inputs(_ node: Node) -> [Node] {
            (registry.handlers(for: node).text == nil ? [] : [node]) + node.children.flatMap(inputs)
        }
        let fields = inputs(try #require(graph.tree.root))
        #expect(fields.count == 3)
    } }
    @Test("an empty inspector shows object guidance until scene settings are explicitly opened")
    func emptyInspector() throws { try WorkbenchUITestSupport.withEnvironment { registry, _ in
        let scene = EditorSceneAdapter(seedPreviewScene: false)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let store = EditorStore()
        graph.install(root: InspectorPanel(store: store, scene: scene).theme(EditorVisualTheme.make(dark: false)))
        graph.computeLayout(width: 330, height: 760)
        func inputCount(_ node: Node) -> Int {
            (registry.handlers(for: node).text == nil ? 0 : 1) + node.children.reduce(0) { $0 + inputCount($1) }
        }
        let root = try #require(graph.tree.root)
        #expect(scene.entityCount == 0)
        #expect(inputCount(root) == 0)
        store.dispatch(.setInspectorSceneSettingsVisible(true))
        graph.recomposer.commitAll()
        graph.computeLayout(width: 330, height: 760)
        #expect(inputCount(try #require(graph.tree.root)) > 3)
    } }

    @Test("mixed numeric fields preserve the batch on blur and commit a typed primary value once")
    func mixedNumber() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        var writes = 0
        var value: Float = 5
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: NumberField(value: Binding(get: { value }, set: { value = $0; writes += 1 }),
                                       mixedValueLabel: "Mixed value"))
        graph.computeLayout(width: 160, height: 40)
        let field = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { registry.handlers(for: $0).text != nil })
        focus.focus(field)
        focus.clear()
        #expect(writes == 0)
        focus.focus(field)
        _ = registry.handlers(for: field).text?("5", .target)
        focus.clear()
        #expect(writes == 1)
        #expect(value == 5)
    } }

    @Test("diagnostic navigation focuses the script at the requested line and column")
    func scriptCaret() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        let source = "let first = 1\nlet second = \"😀\"\nlet failure = missing"
        var label = "Ln 1, Col 1"
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ScriptCodeEditor(source: .constant(source), hover: .constant(.hidden),
            caretLabel: Binding(get: { label }, set: { label = $0 }), onChange: { _ in },
            navigation: .init(scriptID: "Test", line: 2, column: 4), onHover: { _ in }, onHoverEnd: {}))
        graph.computeLayout(width: 600, height: 400)
        let field = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { registry.handlers(for: $0).text != nil })
        #expect(focus.focused === field)
        #expect(label == "Ln 3, Col 5")
        _ = registry.handlers(for: field).key?(KeyEvent(scancode: ComposeScancode.arrowRight, keycode: 0,
                                                        modifiers: [], isRepeat: false), .target)
        #expect(label == "Ln 3, Col 6")
    } }

    @Test("compact windows show one full-width panel and can switch to another dock")
    func compactWorkspace() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let document = WorkspaceDocument(
            panels: ["viewport": WorkspacePanel(id: "viewport", title: "Viewport"),
                     "scripts": WorkspacePanel(id: "scripts", title: "Scripts")],
            groups: ["center": WorkspaceTabGroup(id: "center", panels: ["viewport"], activePanelID: "viewport"),
                     "bottom": WorkspaceTabGroup(id: "bottom", panels: ["scripts"], activePanelID: "scripts")],
            slots: WorkspaceSlot.standardEditorSlots(center: .group("center"), bottom: .group("bottom")), layoutTree: .group("center"))
        let controller = WorkspaceController(document: document)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: WorkspaceView(controller: controller, compact: true) { id in
            AnyView(Text(id.rawValue).flex().debugName("test-" + id.rawValue))
        })
        graph.computeLayout(width: 560, height: 640)
        var snapshot = graph.layoutSnapshot()
        #expect(snapshot.contains { $0.debugName == "test-viewport" && $0.absoluteFrame.width >= 550 })
        #expect(!snapshot.contains { $0.debugName == "test-scripts" })
        _ = controller.dispatch(.setActivePanel(groupID: "bottom", panelID: "scripts"))
        graph.recomposer.commitAll()
        graph.computeLayout(width: 560, height: 640)
        snapshot = graph.layoutSnapshot()
        #expect(snapshot.contains { $0.debugName == "test-scripts" && $0.absoluteFrame.width >= 550 })
        #expect(!snapshot.contains { $0.debugName == "test-viewport" })
        #expect(controller.document == document)
    } }
}
