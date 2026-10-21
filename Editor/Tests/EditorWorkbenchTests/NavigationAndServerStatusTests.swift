@testable import EditorUI
import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing

@Suite("Navigation and language server controls", .serialized)
@MainActor
struct NavigationAndServerStatusTests {
    @Test func visibleNavigationAndServerSettings() throws {
        try WorkbenchUITestSupport.withEnvironment { registry, focus in
            let previousPortals = PortalStoreHolder.current
            let previousCapture = PointerCaptureHolder.current
            let portals = PortalStore()
            let capture = PointerCapture()
            PortalStoreHolder.current = portals
            PointerCaptureHolder.current = capture
            defer {
                portals.clear()
                PortalStoreHolder.current = previousPortals
                PointerCaptureHolder.current = previousCapture
            }
            let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: project) }
            let app = try EditorApplication(projectDirectory: project.path)
            defer { app.shutdown() }
            app.scene.setEditorViewportCameraEnabled(true)
            let originalCamera = app.scene.currentRenderCamera()
            let originalScene = app.scene.manifest()
            var settingsOpened = false
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                Column(alignment: .leading, spacing: 20) {
                    ViewportNavigationSelector(scene: app.scene)
                    LanguageServerStatus(app: app, snapshot: app.workstation.scripts.snapshot, onCommand: {
                        if case .openSettings = $0 { settingsOpened = true }
                    })
                }
            }.theme(EditorVisualTheme.make(dark: true)))
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            func settle() {
                for _ in 0..<4 {
                    graph.recomposer.commitAll()
                    graph.computeLayout(width: 600, height: 650)
                }
            }
            func activate(_ name: String) throws {
                try WorkbenchUITestSupport.activate(name, in: graph.tree.root, registry: registry)
                settle()
            }
            settle()
            try activate("viewport-navigation")
            try activate("viewport-orbit-right")
            #expect(app.scene.currentRenderCamera() != originalCamera)
            let orbited = app.scene.currentRenderCamera()
            try activate("viewport-pan-left")
            #expect(app.scene.currentRenderCamera().target != orbited.target)
            try activate("viewport-reset-view")
            #expect(app.scene.currentRenderCamera() == originalCamera)
            let afterNavigation = app.scene.manifest()
            #expect(afterNavigation.roots == originalScene.roots)
            #expect(afterNavigation.revision == originalScene.revision)
            #expect(!app.scene.canUndoEdit)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: ComposeScancode.escape, keycode: 0, modifiers: [], isRepeat: false)))
            settle()
            try activate("editor-status-language-server")
            let item = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable("language-server-settings")
            })
            let frame = item.absoluteFrame
            let click = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(click))
            dispatcher.dispatch(.mouseButtonUp(click))
            settle()
            #expect(settingsOpened)
            #expect(portals.entries.isEmpty)
        }
    }
}
