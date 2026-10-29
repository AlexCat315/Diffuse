import AssetPipeline
@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import Testing
@testable import EditorUI

@Suite("Loop cut controls",.serialized)
@MainActor
struct MeshLoopCutControlsTests {
    @Test("Ctrl R stays local to the viewport; fields, menu, confirm and Escape retain focus and fit narrow panes",arguments: [Float(320),Float(800)])
    func controls(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { registry,focus in
        let oldCapture = PointerCaptureHolder.current, oldPortals = PortalStoreHolder.current
        let capture = PointerCapture(), portals = PortalStore()
        PointerCaptureHolder.current = capture; PortalStoreHolder.current = portals
        defer { PointerCaptureHolder.current = oldCapture; portals.clear(); PortalStoreHolder.current = oldPortals }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loop-cut-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown(); EditorViewportDropTarget.frame = nil }
        let id = try #require(app.geometryAuthoring.create(.box)), model = app.meshEditing
        #expect(model.setMode(.edge))
        let seed = try #require(model.picker()?.edges.firstIndex(of: .init(0,1)))
        model.select([seed])
        let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
        var fallbackCount = 0
        graph.install(root: StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot {
                    Column {
                        ViewportPanel(app: app,scene: app.scene).frame(width: width,height: 560)
                        TextField("Unrelated",text: Binding(get: { TextBuffer.empty },set: { _ in })).debugName("loop-unrelated-input")
                    }
                    ShortcutHost(onKeyDown: { key in
                        guard key.scancode == 21,key.modifiers.hasCtrl else { return false }
                        fallbackCount += 1; return true
                    })
                }
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
        func focusField(_ name: String) throws {
            let field = try WorkbenchUITestSupport.named(name,in: graph.tree.root)
            focus.focus(try #require(WorkbenchUITestSupport.firstNode(field) { registry.handlers(for: $0).text != nil })); settle()
        }
        settle(); try focusField("loop-unrelated-input")
        key(21,[.lctrl]); #expect(!model.isLoopCutting && fallbackCount == 1)
        let frame = try #require(EditorViewportDropTarget.frame)
        click(frame.x+4,frame.y+4); model.select([seed]); settle()
        let viewport = try #require(focus.focused), presentation = app.store.uiRefreshRevision
        key(21,[.lctrl])
        #expect(model.isLoopCutting && model.selection.count == 4 && fallbackCount == 1)
        #expect(focus.focused === viewport)
        try focusField("mesh-loop-cut-count")
        key(4,[.lgui]); dispatcher.dispatch(.textInput("3")); key(40)
        #expect(model.loopCutCount == 3 && model.controlMesh()?.faces.count == 18)
        try focusField("mesh-loop-cut-slide")
        key(4,[.lgui]); dispatcher.dispatch(.textInput("0.5")); key(40)
        #expect(abs(model.loopCutSlide-0.5) < 1e-6 && model.isLoopCutPreviewValid)
        #expect(model.selection.count == 12 && app.store.uiRefreshRevision == presentation)
        for name in ["mesh-mode-menu","mesh-loop-cut-controls","mesh-loop-cut-confirm","mesh-loop-cut-cancel","viewport-view-menu"] {
            let node = try WorkbenchUITestSupport.named(name,in: graph.tree.root)
            #expect(node.absoluteFrame.minX >= 0 && node.absoluteFrame.maxX <= CGFloat(width))
        }
        let url = URL(fileURLWithPath: try #require(app.scene.referencedAsset(for: id)?.absolutePath))
        #expect(try GeometryDocument.load(from: url).source.evaluate().faces.count == 6)
        try activate("mesh-loop-cut-confirm")
        #expect(!model.isLoopCutting && model.selection.count == 12)
        #expect(try GeometryDocument.load(from: url).source.evaluate().faces.count == 18)
        app.undo(); model.synchronize(); model.select([seed]); settle()
        try activate("mesh-tools-menu")
        let item = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) { $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable("mesh-loop-cut") })
        click(Float(item.absoluteFrame.midX),Float(item.absoluteFrame.midY)); #expect(model.isLoopCutting)
        try focusField("mesh-loop-cut-slide"); key(41)
        #expect(!model.hasInteractiveEdit && model.selection == [seed])
        #expect(model.beginLoopCut()); settle(); try activate("mesh-loop-cut-cancel")
        focus.focus(viewport); key(21,[.lctrl]); key(40)
        #expect(!model.isLoopCutting && model.controlMesh()?.faces.count == 10)
        app.undo(); model.synchronize(); model.select([seed]); #expect(model.beginLoopCut())
        _ = MeshViewportInteraction.handle(.windowFocusLost,app: app)
        #expect(!model.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
    } }
}
