@testable import EditorApp
@testable import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import RenderBackend
import Testing

@Suite("Productivity regressions", .serialized)
struct ProductivityRegressionTests {
    @Test("the command palette is centered and its search and results fill the card",
          arguments: [Float(600), 1280], [Float(360), 600])
    func commandPaletteLayout(width: Float, height: Float) throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-palette-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(
            mode: .level, preset: .levelDefault, registry: registry))
        app.store.dispatch(.setCommandPaletteVisible(true))
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                EmptyView().frame(width: .percent(100), height: .percent(100))
            } portals: {
                CommandPalettePresentation(app: app, controller: controller, registry: registry,
                                           availableHeight: height)
            })
            graph.computeLayout(width: width, height: height)
            graph.recomposer.commitAll()
            graph.computeLayout(width: width, height: height)
            let layout = graph.layoutSnapshot()
            let card = try #require(layout.first { $0.debugName == "command-palette-card" }?.absoluteFrame)
            let search = try #require(layout.first { $0.debugName == "command-palette-search" }?.absoluteFrame)
            let results = try #require(layout.first { $0.debugName == "command-palette-results" }?.absoluteFrame)
            #expect(card.minY >= 0)
            #expect(card.maxY <= CGFloat(height))
            #expect(abs(card.midY - CGFloat(height) / 2) < 1)
            #expect(card.width >= 540)
            #expect(search.width == card.width)
            #expect(results.width == card.width)
        }
    }

    @Test("asset empty states and workflow details stay inside a short dock",
          arguments: [Float(320), 778], [Float(138), 360])
    func assetDockLayout(width: Float, height: Float) throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-assets-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        try WorkbenchUITestSupport.withEnvironment { registry, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Box(direction: .column, alignItems: .stretch) {
                AssetBrowserPanel(app: app).flex()
            }.frame(width: width, height: height))
            func check(_ name: String) throws {
                graph.recomposer.commitAll()
                graph.computeLayout(width: width, height: height)
                let frame = try #require(graph.layoutSnapshot().first { $0.debugName == name }?.absoluteFrame)
                #expect(frame.minY >= 50)
                #expect(frame.height > 0)
                #expect(frame.maxY <= CGFloat(height))
                #expect(frame.maxX <= CGFloat(width))
            }
            try check("asset-empty-scroll")
            try WorkbenchUITestSupport.activate("asset-missing-resources", in: graph.tree.root, registry: registry)
            try check("asset-workflow-scroll")
            #expect(!graph.layoutSnapshot().contains { $0.debugName == "asset-empty-scroll" })
            try WorkbenchUITestSupport.activate("asset-workflow-close", in: graph.tree.root, registry: registry)
            try check("asset-empty-scroll")
        }
    }

    @Test("scene and game viewports fill their workspace at every panel width",
          arguments: [EditorViewportMode.scene, .game], [Float(320), 778, 1280])
    func viewportWorkspaceLayout(mode: EditorViewportMode, width: Float) throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-viewport-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        app.store.dispatch(.setViewportMode(mode))
        try WorkbenchUITestSupport.withEnvironment { registry, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: EditorViewportWorkspacePanel(app: app).frame(width: width, height: 480))
            graph.computeLayout(width: width, height: 480)
            let viewport = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                registry.handlers(for: $0).pointerRoute == .viewport
            })
            #expect(Float(viewport.frame.width) == width)
            #expect(viewport.frame.height > 320)
            #expect(viewport.absoluteFrame.maxY == 480)
        }
    }

    @Test("letterbox bars neither focus the game nor forward pointer input")
    func letterboxInput() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        let capture = PointerCapture()
        let previousCapture = PointerCaptureHolder.current
        PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = previousCapture }
        var events: [InputEvent] = []
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ViewportHost(surface: .init(), contentAspectRatio: 1,
            onInputEvent: { events.append($0) }) { EmptyView() }.frame(width: 400, height: 200))
        graph.computeLayout(width: 400, height: 200)
        let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
        let bar = MouseButtonEvent(button: .left, x: 25, y: 100, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(bar))
        dispatcher.dispatch(.mouseButtonUp(bar))
        dispatcher.dispatch(.mouseMotion(.init(x: 25, y: 100, deltaX: 1, deltaY: 0)))
        #expect(focus.focused == nil)
        #expect(capture.target == nil)
        #expect(events.isEmpty)
        let image = MouseButtonEvent(button: .left, x: 200, y: 100, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(image))
        dispatcher.dispatch(.mouseMotion(.init(x: 25, y: 100, deltaX: -175, deltaY: 0)))
        dispatcher.dispatch(.mouseButtonUp(bar))
        #expect(focus.focused != nil)
        #expect(capture.target == nil)
        #expect(events.count == 3)
        events.removeAll()
        dispatcher.dispatch(.mouseButtonDown(bar))
        #expect(focus.focused == nil)
        #expect(events.isEmpty)
    } }

    @Test("clicking the game image retains input focus through recomposition")
    func gameImageFocus() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-game-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        app.store.dispatch(.setViewportMode(.game))
        try WorkbenchUITestSupport.withEnvironment { registry, focus in
            let capture = PointerCapture()
            let previousCapture = PointerCaptureHolder.current
            PointerCaptureHolder.current = capture
            defer { PointerCaptureHolder.current = previousCapture }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: EditorViewportWorkspacePanel(app: app).frame(width: 778, height: 480))
            graph.computeLayout(width: 778, height: 480)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            let image = MouseButtonEvent(button: .left, x: 389, y: 240, clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(image))
            dispatcher.dispatch(.mouseButtonUp(image))
            #expect(app.store.gamePreviewFocused)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 778, height: 480)
            let viewport = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                registry.handlers(for: $0).pointerRoute == .viewport
            })
            #expect(focus.focused === viewport)
            #expect(app.store.gamePreviewFocused)
        }
    }

    @Test("a mixed numeric edit commits once across Return and blur")
    func mixedNumericCommit() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        var writes = 0
        var value: Float = 5
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: NumberField(value: Binding(get: { value }, set: { value = $0; writes += 1 }),
                                       mixedValueLabel: "Mixed value"))
        graph.computeLayout(width: 160, height: 40)
        let node = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { registry.handlers(for: $0).text != nil })
        focus.focus(node)
        graph.recomposer.commitAll()
        _ = registry.handlers(for: node).text?("5", .target)
        _ = registry.handlers(for: node).key?(.init(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false), .target)
        focus.clear()
        #expect(writes == 1)
        #expect(value == 5)
    } }

    @Test("focusing and leaving a numeric field preserves its underlying precision")
    func untouchedNumericPrecision() throws { try WorkbenchUITestSupport.withEnvironment { registry, focus in
        var value: Float = 0.12345679
        var writes = 0
        let original = value
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: NumberField(value: Binding(get: { value }, set: { value = $0; writes += 1 }), decimals: 2))
        graph.computeLayout(width: 160, height: 40)
        let node = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { registry.handlers(for: $0).text != nil })
        focus.focus(node)
        graph.recomposer.commitAll()
        focus.clear()
        #expect(value == original)
        #expect(writes == 0)
    } }

    @Test("game preview keeps its keyboard target when playback resumes in the same mode")
    func previewFocus() {
        let store = EditorStore()
        store.dispatch(.setViewportMode(.game))
        store.dispatch(.setGamePreviewFocused(true))
        store.dispatch(.setViewportMode(.game))
        #expect(store.gamePreviewFocused)
        store.dispatch(.setViewportMode(.scene))
        #expect(!store.gamePreviewFocused)
    }
}
