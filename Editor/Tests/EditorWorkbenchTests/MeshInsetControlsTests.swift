import AssetPipeline
@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import Testing
@testable import EditorUI

@Suite("Mesh inset controls",.serialized)
@MainActor
struct MeshInsetControlsTests {
    @Test("I opens compact controls; width input retains preview across focus changes; confirm and cancel edit history",arguments: [Float(320),Float(800)])
    func controls(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { registry,focus in
        let oldCapture = PointerCaptureHolder.current, oldPortals = PortalStoreHolder.current
        let capture = PointerCapture(), portals = PortalStore()
        PointerCaptureHolder.current = capture; PortalStoreHolder.current = portals
        defer { PointerCaptureHolder.current = oldCapture; portals.clear(); PortalStoreHolder.current = oldPortals }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-inset-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown(); EditorViewportDropTarget.frame = nil }
        let id = try #require(app.geometryAuthoring.create(.box)), model = app.meshEditing
        #expect(model.setMode(.face)); model.select([1])
        let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
        graph.install(root: StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot { ViewportPanel(app: app,scene: app.scene).frame(width: width,height: 560) }
            }
        })
        let dispatcher = EventDispatcher(tree: graph.tree,interactions: registry,capture: capture,focusChain: focus)
        func settle() {
            for _ in 0..<4 {
                graph.recomposer.commitAll(); graph.computeLayout(width: width,height: 700)
                NodeRenderer().render(root: graph.tree.root!,into: DrawList())
            }
        }
        func key(_ scan: UInt32,_ modifiers: KeyModifiers = []) {
            dispatcher.dispatch(.keyDown(.init(scancode: scan,keycode: 0,modifiers: modifiers,isRepeat: false))); settle()
        }
        func click(_ x: Float,_ y: Float) {
            let event = MouseButtonEvent(button: .left,x: x,y: y,clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event)); settle()
        }
        func activate(_ name: String) throws {
            try WorkbenchUITestSupport.activate(name,in: graph.tree.root,registry: registry); settle()
        }
        settle()
        let frame = try #require(EditorViewportDropTarget.frame)
        click(frame.x+4,frame.y+4); model.select([1]); settle()
        let viewport = try #require(focus.focused), presentation = app.store.uiRefreshRevision
        key(12)
        #expect(model.isInsetting && model.controlMesh()?.faces.count == 10)
        #expect(focus.focused === viewport)
        let field = try WorkbenchUITestSupport.named("mesh-inset-width",in: graph.tree.root)
        let input = try #require(WorkbenchUITestSupport.firstNode(field) { registry.handlers(for: $0).text != nil })
        focus.focus(input); settle()
        #expect(model.isInsetting) // Header focus must not cancel the preview.
        key(4,[.lgui]); dispatcher.dispatch(.textInput("0.2")); key(40)
        #expect(abs(model.insetDistance-0.2) < 1e-6 && model.isInsetPreviewValid)
        #expect(app.store.uiRefreshRevision == presentation)
        for name in ["mesh-mode-menu","mesh-inset-controls","mesh-inset-confirm","mesh-inset-cancel","viewport-view-menu"] {
            let node = try WorkbenchUITestSupport.named(name,in: graph.tree.root)
            #expect(node.absoluteFrame.minX >= 0 && node.absoluteFrame.maxX <= CGFloat(width))
        }
        let url = URL(fileURLWithPath: try #require(app.scene.referencedAsset(for: id)?.absolutePath))
        #expect(try GeometryDocument.load(from: url).source.evaluate().faces.count == 6)
        try activate("mesh-inset-confirm")
        #expect(!model.isInsetting && model.selection == [1])
        #expect(try GeometryDocument.load(from: url).source.evaluate().faces.count == 10)
        app.undo(); model.synchronize(); model.select([1]); settle()
        #expect(model.controlMesh()?.faces.count == 6)
        #expect(model.beginInset()); settle(); try activate("mesh-inset-cancel")
        #expect(!model.isInsetting && model.controlMesh()?.faces.count == 6)
        #expect(model.beginInset()); settle()
        let nextField = try WorkbenchUITestSupport.named("mesh-inset-width",in: graph.tree.root)
        focus.focus(try #require(WorkbenchUITestSupport.firstNode(nextField) { registry.handlers(for: $0).text != nil })); settle()
        key(41); #expect(!model.isInsetting)
        focus.focus(viewport); key(12); #expect(model.isInsetting)
        key(41); #expect(!model.isInsetting)
        key(12); key(40); #expect(!model.isInsetting && model.controlMesh()?.faces.count == 10)
        #expect(model.beginInset())
        _ = MeshViewportInteraction.handle(.windowFocusLost,app: app)
        #expect(!model.hasInteractiveEdit)
    } }
}
