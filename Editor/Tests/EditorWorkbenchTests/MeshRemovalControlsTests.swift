import AssetPipeline
@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import CoveUIWorkspace
import SIMDCompat
import Testing
@testable import EditorUI

@Suite("Mesh remove controls",.serialized)
@MainActor
struct MeshRemovalControlsTests {
    @Test("menu dissolve, Delete and application commands edit topology while preserving viewport focus and the object")
    func menuAndKeyboard() throws { try WorkbenchUITestSupport.withEnvironment { registry,focus in
        let previousPortals = PortalStoreHolder.current, previousCapture = PointerCaptureHolder.current
        let portals = PortalStore(), capture = PointerCapture()
        PortalStoreHolder.current = portals; PointerCaptureHolder.current = capture
        defer { portals.clear(); PortalStoreHolder.current = previousPortals; PointerCaptureHolder.current = previousCapture }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-remove-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown(); EditorViewportDropTarget.frame = nil }
        let id = try #require(app.geometryAuthoring.create(.plane))
        let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
        graph.install(root: StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot { ViewportPanel(app: app,scene: app.scene).frame(width: 800,height: 560) }
            }
        })
        let dispatcher = EventDispatcher(tree: graph.tree,interactions: registry,capture: capture,focusChain: focus)
        func settle() {
            for _ in 0..<4 {
                graph.recomposer.commitAll(); graph.computeLayout(width: 800,height: 700)
                NodeRenderer().render(root: graph.tree.root!,into: DrawList())
            }
        }
        func activate(_ name: String) throws {
            try WorkbenchUITestSupport.activate(name,in: graph.tree.root,registry: registry); settle()
        }
        func click(_ x: Float,_ y: Float) {
            let event = MouseButtonEvent(button: .left,x: x,y: y,clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event)); settle()
        }
        func choose(_ id: String) throws {
            let item = try #require(WorkbenchUITestSupport.firstNode(graph.tree.root) {
                $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable(id)
            })
            click(Float(item.absoluteFrame.midX),Float(item.absoluteFrame.midY))
        }
        settle()
        try activate("mesh-mode-menu"); try choose("mesh-mode-face")
        app.meshEditing.selectAll(); settle()
        try activate("mesh-tools-menu"); try choose("mesh-triangulate")
        #expect(app.meshEditing.controlMesh()?.faces.count == 2)
        try activate("mesh-mode-menu"); try choose("mesh-mode-edge")
        let mesh = try #require(app.meshEditing.controlMesh())
        let index = try #require(mesh.edges.firstIndex { edge in mesh.faces.allSatisfy { $0.vertices.contains(edge.a) && $0.vertices.contains(edge.b) } })
        app.meshEditing.select([index]); settle()
        try activate("mesh-tools-menu"); try choose("mesh-dissolve")
        #expect(app.meshEditing.controlMesh()?.faces.count == 1 && app.meshEditing.selection.isEmpty)
        app.undo(); settle(); #expect(app.meshEditing.controlMesh()?.faces.count == 2)
        app.redo(); settle(); #expect(app.meshEditing.controlMesh()?.faces.count == 1)
        try activate("mesh-mode-menu"); try choose("mesh-mode-face")
        let frame = try #require(EditorViewportDropTarget.frame)
        let projection = try #require(EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: frame))
        let center = try #require(projection.project(.zero))
        click(center.x,center.y)
        #expect(app.meshEditing.selection.count == 1)
        let viewport = try #require(focus.focused)
        dispatcher.dispatch(.keyDown(.init(scancode: 76,keycode: 0,modifiers: [],isRepeat: false))); settle()
        #expect(app.meshEditing.controlMesh()?.faces.isEmpty == true && app.scene.entitySummary(id: id) != nil)
        #expect(focus.focused === viewport)
        dispatcher.dispatch(.keyDown(.init(scancode: 76,keycode: 0,modifiers: [],isRepeat: false))); settle()
        #expect(app.scene.entitySummary(id: id) != nil)
        let path = try #require(app.scene.referencedAsset(for: id)?.absolutePath)
        #expect(try GeometryDocument.load(from: URL(fileURLWithPath: path)).source.evaluate().faces.isEmpty)
        app.undo(); settle(); #expect(app.meshEditing.controlMesh()?.faces.count == 1)
        app.meshEditing.selectAll(); settle()
        try activate("mesh-tools-menu"); try choose("mesh-delete")
        #expect(app.meshEditing.controlMesh()?.faces.isEmpty == true)
        app.undo(); settle(); app.meshEditing.selectAll()
        let panels = WorkspacePanelRegistry([WorkspacePanelDescriptor(id: "viewport",title: "Viewport",defaultSlot: .center) { EmptyView() }])
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(registry: panels))
        EditorCommandDispatcher.handle(.deleteSelection,app: app,controller: controller,registry: panels)
        #expect(app.meshEditing.controlMesh()?.faces.isEmpty == true && app.scene.entitySummary(id: id) != nil)
        #expect(portals.entries.isEmpty)
    } }
}
