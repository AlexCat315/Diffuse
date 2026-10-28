import AssetPipeline
@testable import EditorCore
import EngineKernel
import Foundation
import CoveUICompose
import CoveUIRuntime
import RenderBackend
import SIMDCompat
import Testing
@testable import EditorUI

@Suite("Viewport mesh editing", .serialized)
@MainActor
struct MeshViewportEditingTests {
    @Test("viewport focus and Tab routing survive selection recomposition",arguments: [false,true])
    func focusRouting(actualPanel: Bool) throws { try WorkbenchUITestSupport.withEnvironment { registry,focus in
        let capture = PointerCapture()
        let oldCapture = PointerCaptureHolder.current; PointerCaptureHolder.current = capture
        defer { PointerCaptureHolder.current = oldCapture }
        try withApp { app,_,_ in
            #expect(app.meshEditing.setMode(.face))
            let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
            if actualPanel {
                graph.install(root: ViewportPanel(app: app,scene: app.scene).theme(EditorVisualTheme.make(dark: false)))
            } else {
                graph.install(root: StoreScope(app.store) { store in
                    let _ = store.uiRefreshRevision
                    ViewportHost(surface: ViewportSurfaceState(),onInputEvent: { event in
                        _ = MeshViewportInteraction.handle(event,app: app)
                    },onScreenFrameChange: { EditorViewportDropTarget.frame = $0 })
                        .frame(width: 800,height: 600)
                })
            }
            graph.computeLayout(width: 800,height: 600)
            NodeRenderer().render(root: try #require(graph.tree.root),into: DrawList())
            let dispatcher = EventDispatcher(tree: graph.tree,interactions: registry,capture: capture,focusChain: focus)
            let frame = try #require(EditorViewportDropTarget.frame)
            let click = MouseButtonEvent(button: .left,x: frame.x+frame.width/2,y: frame.y+frame.height/2,clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(click)); dispatcher.dispatch(.mouseButtonUp(click))
            #expect(app.meshEditing.selection == [1])
            let viewport = try #require(focus.focused)
            graph.recomposer.commitAll(); graph.computeLayout(width: 800,height: 600)
            #expect(focus.focused === viewport)
            dispatcher.dispatch(.keyDown(.init(scancode: 43,keycode: 0,modifiers: [],isRepeat: false)))
            #expect(!app.meshEditing.isEditing)
        }
    } }

    @Test("rotation and scale gizmos operate about the selected control-vertex pivot",arguments: [EditorGizmoMode.rotate,.scale])
    func rotationAndScale(mode: EditorGizmoMode) throws { try withApp { app,id,frame in
        #expect(app.meshEditing.setMode(.vertex)); app.meshEditing.selectAll()
        let original = try #require(app.meshEditing.controlMesh())
        MeshViewportInteraction.snapshot(app: app,mode: mode,space: .world)
        let snapshot = try #require(EditorGizmoController.shared.snapshot)
        let projection = try #require(EditorViewportProjection(camera: snapshot.camera,frame: frame))
        let radius = snapshot.axisLength
        let startWorld = mode == .rotate ? SIMD3(radius*0.70710678,radius*0.70710678,0) : SIMD3(radius,0,0)
        let endWorld = mode == .rotate ? SIMD3(-radius*0.70710678,radius*0.70710678,0) : SIMD3(radius*1.5,0,0)
        let start = try #require(projection.project(startWorld)), end = try #require(projection.project(endWorld))
        #expect(MeshViewportInteraction.handle(.mouseButtonDown(.init(button: .left,x: start.x,y: start.y,clicks: 1)),app: app))
        #expect(app.meshEditing.isTransforming)
        #expect(MeshViewportInteraction.handle(.mouseMotion(.init(x: end.x,y: end.y,deltaX: end.x-start.x,deltaY: end.y-start.y)),app: app))
        #expect(MeshViewportInteraction.handle(.mouseButtonUp(.init(button: .left,x: end.x,y: end.y,clicks: 1)),app: app))
        let point = try #require(app.meshEditing.controlMesh()?.positions[0])
        let expected = mode == .rotate ? SIMD3(-original.positions[0].y,original.positions[0].x,original.positions[0].z)
            : SIMD3(original.positions[0].x*1.5,original.positions[0].y,original.positions[0].z)
        #expect(simd_length(point-expected) < 1e-4)
        #expect(app.scene.entityLocalMatrix(id) == matrix_identity_float4x4)
        app.undo(); #expect(app.meshEditing.controlMesh() == original)
    } }

    @Test("toolbar, surface selection and region extrusion operate on the saved control mesh")
    func selectionAndExtrusion() throws { try WorkbenchUITestSupport.withEnvironment { registry,_ in
        try withApp { app,id,frame in
            let graph = ViewGraph(tree: NodeTree(),recomposer: Recomposer())
            graph.install(root: StoreScope(app.store) { store in
                let _ = store.uiRefreshRevision
                let _: Void = app.meshEditing.synchronize()
                Column {
                    MeshEditControls(app: app)
                    InspectorPanel(store: app.store,scene: app.scene).flex()
                }
            }.theme(EditorVisualTheme.make(dark: false)))
            graph.computeLayout(width: 360,height: 800)
            try WorkbenchUITestSupport.activate("mesh-edit-toggle",in: graph.tree.root,registry: registry)
            graph.recomposer.commitAll()
            #expect(app.meshEditing.isEditing)
            try WorkbenchUITestSupport.activate("mesh-mode-face",in: graph.tree.root,registry: registry)
            graph.recomposer.commitAll()
            let projection = try #require(EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: frame))
            let point = try #require(projection.project(.zero))
            let pointer = MouseButtonEvent(button: .left,x: point.x,y: point.y,clicks: 1)
            #expect(MeshViewportInteraction.handle(.mouseButtonDown(pointer),app: app))
            #expect(MeshViewportInteraction.handle(.mouseButtonUp(pointer),app: app))
            #expect(app.meshEditing.selection == [1])
            graph.recomposer.commitAll(); graph.computeLayout(width: 360,height: 800)
            try WorkbenchUITestSupport.activate("inspector-field-mesh-edit-selection/mesh-extrude-region",in: graph.tree.root,registry: registry)
            #expect(app.meshEditing.controlMesh()?.faces.count == 10)
            let asset = try #require(app.scene.referencedAsset(for: id))
            let saved = try GeometryDocument.load(from: URL(fileURLWithPath: asset.absolutePath))
            #expect(try saved.source.evaluate().faces.count == 10)
            app.undo(); graph.recomposer.commitAll()
            #expect(app.meshEditing.controlMesh()?.faces.count == 6)
            #expect(app.meshEditing.selection.isEmpty)
            let draw = DrawList(); MeshViewportOverlay.draw(app: app,list: draw,frame: frame)
            NodeRenderer().render(root: try #require(graph.tree.root),into: draw)
        }
    } }

    @Test("world gizmo dragging transforms vertices of a rotated negatively scaled object without moving the object")
    func gizmoTransform() throws { try withApp { app,id,frame in
        var world = simd_float4x4(simd_quatf(angle: .pi/6,axis: SIMD3(0,0,1)))
        world.columns.0 *= -2; world.columns.1 *= 1.5; world.columns.2 *= 0.5
        world.columns.3 = SIMD4(0.5,-0.2,0,1)
        app.scene.setEntityLocalMatrix(id,to: world)
        #expect(app.meshEditing.setMode(.vertex)); app.meshEditing.selectAll()
        let before = try #require(app.meshEditing.controlMesh())
        MeshViewportInteraction.snapshot(app: app,mode: .translate,space: .world)
        let snapshot = try #require(EditorGizmoController.shared.snapshot)
        let projection = try #require(EditorViewportProjection(camera: snapshot.camera,frame: frame))
        let start = try #require(projection.project(snapshot.entityWorldPosition+SIMD3(snapshot.axisLength,0,0)))
        let down = MouseButtonEvent(button: .left,x: start.x,y: start.y,clicks: 1)
        #expect(MeshViewportInteraction.handle(.mouseButtonDown(down),app: app))
        #expect(app.meshEditing.isTransforming)
        #expect(MeshViewportInteraction.handle(.mouseMotion(.init(x: start.x+30,y: start.y,deltaX: 30,deltaY: 0)),app: app))
        let worldDx = 30*snapshot.camera.orthographicHeight/frame.height
        let local = simd_inverse(world)*SIMD4(worldDx,0,0,0)
        let expected = before.positions[0]+SIMD3(local.x,local.y,local.z)
        let preview = try #require(app.meshEditing.controlMesh())
        #expect(simd_length(preview.positions[0]-expected) < 1e-4)
        #expect(app.scene.entityLocalMatrix(id) == world)
        #expect(MeshViewportInteraction.handle(.mouseButtonUp(.init(button: .left,x: start.x+30,y: start.y,clicks: 1)),app: app))
        #expect(!app.meshEditing.isTransforming)
        app.undo()
        #expect(app.meshEditing.controlMesh() == before)
        app.redo()
        #expect(app.meshEditing.controlMesh() == preview)
        #expect(app.meshEditing.beginTransform())
        var delta = matrix_identity_float4x4; delta.columns.3.y = 1
        #expect(app.meshEditing.previewTransform(delta))
        #expect(!MeshViewportInteraction.handle(.windowFocusLost,app: app))
        #expect(!app.meshEditing.isTransforming && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(app.meshEditing.controlMesh() == preview)
    } }

    @Test("marquee selects control components and keyboard routing cannot delete the whole object")
    func marqueeAndKeys() throws { try withApp { app,id,frame in
        #expect(app.meshEditing.setMode(.vertex))
        app.meshEditing.setXray(true)
        app.store.dispatch(.setGizmoMode(.boxSelect))
        let down = MouseButtonEvent(button: .left,x: frame.x+10,y: frame.y+10,clicks: 1)
        #expect(MeshViewportInteraction.handle(.mouseButtonDown(down),app: app))
        #expect(MeshViewportInteraction.handle(.mouseMotion(.init(x: frame.x+frame.width-10,y: frame.y+frame.height-10,deltaX: 100,deltaY: 100)),app: app))
        #expect(MeshViewportInteraction.handle(.mouseButtonUp(.init(button: .left,x: frame.x+frame.width-10,y: frame.y+frame.height-10,clicks: 1)),app: app))
        #expect(app.meshEditing.selection.count == 8)
        #expect(MeshViewportInteraction.handle(.keyDown(.init(scancode: 76,keycode: 0,modifiers: [],isRepeat: false)),app: app))
        #expect(app.scene.entitySummary(id: id) != nil)
        #expect(MeshViewportInteraction.handle(.keyDown(.init(scancode: 43,keycode: 0,modifiers: [],isRepeat: false)),app: app))
        #expect(!app.meshEditing.isEditing)
    } }

    private func withApp(_ work: (EditorApplication,UInt64,ViewportScreenFrame) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-viewport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown(); EditorViewportDropTarget.frame = nil; EditorGizmoController.shared.clearDrag(); EditorGizmoController.shared.updateSnapshot(nil) }
        let id = try #require(app.geometryAuthoring.create(.box))
        app.scene.setEditorViewportCameraEnabled(true)
        app.scene.lookAlongAxis(SIMD3(0,0,-1),orthographic: true)
        let frame = ViewportScreenFrame(x: 20,y: 50,width: 800,height: 600)
        EditorViewportDropTarget.frame = frame
        try work(app,id,frame)
    }
}
