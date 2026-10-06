@testable import EditorApp
import EditorCore
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Viewport navigation controls", .serialized)
@MainActor
struct ViewportNavigationControlsTests {
    @Test("view menu activates axis views and snap fields commit independent steps")
    func menusAndSnapFields() throws {
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
            let store = EditorStore()
            var selectedAxis: SIMD3<Float>?
            var selectedProjection: RenderCamera.Projection?
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                Column(alignment: .leading, spacing: 10) {
                    ViewportProjectionSelector(camera: RenderCamera(eye: SIMD3<Float>(0, 0, 5), target: .zero),
                        isEnabled: true, onSelectProjection: { selectedProjection = $0 },
                        onSelectAxis: { selectedAxis = $0 })
                    ViewportSnapSelector(store: store, isEnabled: true)
                }
            }.theme(EditorVisualTheme.make(dark: true)))
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                            capture: capture, focusChain: focus)
            func settle() {
                for _ in 0..<4 {
                    graph.recomposer.commitAll()
                    graph.computeLayout(width: 440, height: 480)
                }
            }
            func click(_ node: Node) {
                let frame = node.absoluteFrame
                let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(event))
                dispatcher.dispatch(.mouseButtonUp(event))
                settle()
            }
            func menuItem(_ id: String) throws -> Node {
                try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                    $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable(id)
                })
            }
            settle()
            try WorkbenchUITestSupport.activate("viewport-projection-selector", in: graph.tree.root, registry: registry)
            settle()
            click(try menuItem("viewport-orthographic"))
            #expect(selectedProjection == .orthographic && portals.entries.isEmpty)
            try WorkbenchUITestSupport.activate("viewport-projection-selector", in: graph.tree.root, registry: registry)
            settle()
            click(try menuItem("viewport-view-bottom"))
            #expect(selectedAxis == SIMD3<Float>(0, 1, 0) && portals.entries.isEmpty)

            try WorkbenchUITestSupport.activate("viewport-snap-selector", in: graph.tree.root, registry: registry)
            settle()
            try WorkbenchUITestSupport.activate("viewport-snap-translate-toggle", in: graph.tree.root, registry: registry)
            settle()
            #expect(store.state.snapping.translateSnapEnabled)
            for (id, text) in [("translate", "0.125"), ("rotate", "15"), ("scale", "0.02")] {
                let subtree = try WorkbenchUITestSupport.named("viewport-snap-\(id)-step", in: graph.tree.root)
                let field = try #require(WorkbenchUITestSupport.firstNode(subtree) { registry.handlers(for: $0).text != nil })
                focus.focus(field)
                settle()
                let handlers = registry.handlers(for: field)
                _ = handlers.key?(KeyEvent(scancode: ComposeScancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false), .target)
                _ = handlers.key?(KeyEvent(scancode: ComposeScancode.backspace, keycode: 0, modifiers: [], isRepeat: false), .target)
                _ = handlers.text?(text, .target)
                settle()
                _ = handlers.key?(KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false), .target)
                settle()
                #expect(field.absoluteFrame.width > 40)
            }
            #expect(store.state.snapping.translateSnapStep == 0.125)
            #expect(store.state.snapping.rotateSnapStepDegrees == 15)
            #expect(store.state.snapping.scaleSnapStep == 0.02)
            #expect(!store.state.snapping.rotateSnapEnabled && !store.state.snapping.scaleSnapEnabled)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: ComposeScancode.escape, keycode: 0, modifiers: [], isRepeat: false)))
            settle()
            #expect(portals.entries.isEmpty)
        }
    }
}
