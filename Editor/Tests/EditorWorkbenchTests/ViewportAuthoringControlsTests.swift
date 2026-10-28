import AssetPipeline
@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import Testing
@testable import EditorUI

@Suite("Compact authoring viewport",.serialized)
@MainActor
struct ViewportAuthoringControlsTests {
    @Test("mode, mesh, transform and view controls edit real assets within a narrow header",arguments: [Float(320),800])
    func authoringMenus(width: Float) throws { try WorkbenchUITestSupport.withEnvironment { registry,focus in
        let previousPortals = PortalStoreHolder.current, previousCapture = PointerCaptureHolder.current
        let portals = PortalStore(), capture = PointerCapture()
        PortalStoreHolder.current = portals; PointerCaptureHolder.current = capture
        defer { portals.clear(); PortalStoreHolder.current = previousPortals; PointerCaptureHolder.current = previousCapture }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("viewport-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown(); EditorViewportDropTarget.frame = nil }
        let id = try #require(app.geometryAuthoring.create(.box))
        #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
        let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
        graph.install(root: LayerRoot {
            ViewportPanel(app: app,scene: app.scene).frame(width: width,height: 560)
        }.theme(EditorVisualTheme.make(dark: true)))
        let dispatcher = EventDispatcher(tree: graph.tree,interactions: registry,capture: capture,focusChain: focus)
        func settle() {
            for _ in 0..<4 {
                graph.recomposer.commitAll(); graph.computeLayout(width: width,height: 700)
                NodeRenderer().render(root: graph.tree.root!,into: DrawList())
            }
        }
        func activate(_ name: String) throws {
            try WorkbenchUITestSupport.activate(name,in: graph.tree.root,registry: registry); settle()
        }
        func choose(_ id: String) throws {
            let item = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable(id)
            })
            let bounds = item.absoluteFrame
            let click = MouseButtonEvent(button: .left,x: Float(bounds.midX),y: Float(bounds.midY),clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(click)); dispatcher.dispatch(.mouseButtonUp(click)); settle()
        }
        settle()
        try activate("mesh-mode-menu"); try choose("mesh-mode-face")
        #expect(app.meshEditing.mode == .face)
        #expect(app.meshEditing.controlMesh()?.faces.count == 6)
        #expect(app.geometryAuthoring.viewportPicker(for: id)?.mesh.faces.count == 24)
        for name in ["mesh-mode-menu","viewport-tool-menu","viewport-transform-menu","mesh-tools-menu","viewport-view-menu"] {
            let bounds = try WorkbenchUITestSupport.named(name,in: graph.tree.root).absoluteFrame
            #expect(bounds.width > 0 && bounds.minX >= 0 && bounds.maxX <= CGFloat(width),"\(name) stays in \(width)pt header")
            #expect(bounds.maxY <= 40)
        }
        try activate("mesh-tools-menu"); try choose("mesh-apply-modifiers")
        #expect(app.meshEditing.controlMesh()?.faces.count == 24)
        #expect(try app.geometryAuthoring.document(for: id)?.modifiers.isEmpty == true)
        app.undo(); settle()
        #expect(app.meshEditing.controlMesh()?.faces.count == 6 && app.meshEditing.hasModifiers)
        app.meshEditing.select([1]); settle()
        try activate("mesh-tools-menu"); try choose("mesh-subdivide")
        #expect(app.meshEditing.controlMesh()?.faces.count == 9 && app.meshEditing.selection.count == 4)
        try activate("mesh-tools-menu"); try choose("mesh-triangulate")
        #expect(app.meshEditing.controlMesh()?.faces.count == 13 && app.meshEditing.selection.count == 8)
        let path = try #require(app.scene.referencedAsset(for: id)?.absolutePath)
        #expect(try GeometryDocument.load(from: URL(fileURLWithPath: path)).source.evaluate().faces.count == 13)
        app.undo(); settle()
        #expect(app.meshEditing.controlMesh()?.faces.count == 9)
        try activate("viewport-tool-menu"); try choose("viewport-tool-e")
        #expect(app.store.gizmoMode == .rotate)
        try activate("viewport-transform-menu"); try activate("viewport-space-world")
        #expect(app.store.gizmoSpace == .world)
        dispatcher.dispatch(.keyDown(.init(scancode: ComposeScancode.escape,keycode: 0,modifiers: [],isRepeat: false))); settle()
        try activate("viewport-view-menu"); try activate("viewport-orthographic")
        #expect(app.scene.currentRenderCamera().projection == .orthographic)
        try activate("viewport-view-menu"); try activate("viewmode-unlit")
        #expect(app.store.viewportShadingMode == .unlit)
        let grid = app.store.viewportGridEnabled
        try activate("viewport-view-menu"); try choose("display-overlays"); try choose("display-grid")
        #expect(app.store.viewportGridEnabled != grid)
        #expect(portals.entries.isEmpty)
    } }
}
