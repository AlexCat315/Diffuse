import AssetPipeline
@testable import EditorCore
import Foundation
import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Mesh render overlays",.serialized)
@MainActor
struct MeshRenderingTests {
    @Test("selected faces fill their actual topology and update immediately on selection, mode and X-Ray changes")
    func selection() throws { try withApp { app,_ in
        #expect(app.meshEditing.setMode(.face)); app.meshEditing.select([1])
        let viewport = RenderDrawableSize(width: 800,height: 600)
        let initial = try #require(app.makeGeometryOverlays(drawableSize: viewport).last)
        let filled = initial.triangles.filter { $0.color.w > 0 }
        #expect(filled.count == 2 && initial.triangles.count == 12)
        #expect(initial.triangles.flatMap { [$0.edgeWidths.x,$0.edgeWidths.y,$0.edgeWidths.z] }.filter { $0 == 2 }.count == 8)
        #expect(filled.allSatisfy { $0.a.z == 0.5 && $0.b.z == 0.5 && $0.c.z == 0.5 && $0.color.w < 1 })
        app.meshEditing.select([])
        #expect(app.makeGeometryOverlays(drawableSize: viewport).last?.triangles.allSatisfy { $0.color.w == 0 } == true)
        app.meshEditing.select([1]); app.meshEditing.setXray(true)
        #expect(app.makeGeometryOverlays(drawableSize: viewport).last?.xray == true)
        #expect(app.meshEditing.setMode(.edge)); app.meshEditing.select([0])
        let edges = try #require(app.makeGeometryOverlays(drawableSize: viewport).last)
        #expect(edges.triangles.allSatisfy { $0.color.w == 0 } && edges.points.isEmpty)
        #expect(edges.triangles.flatMap { [$0.edgeWidths.x,$0.edgeWidths.y,$0.edgeWidths.z] }.filter { $0 == 2 }.count == 2)
        app.store.dispatch(.setViewportMode(.game))
        #expect(app.makeGeometryOverlays(drawableSize: viewport).isEmpty)
    } }

    @Test("concave face fill follows ear clipping, negative world scale, and transient inset/extrusion topology")
    func topology() throws { try withApp { app,id in
        let polygon = PolygonMesh(positions: [SIMD3(0,0,0),SIMD3(2,0,0),SIMD3(2,1,0),SIMD3(1,1,0),SIMD3(1,2,0),SIMD3(0,2,0)],faces: [.init([0,1,2,3,4,5])])
        #expect(app.geometryAuthoring.edit(entityID: id) { $0.source = .polygon(mesh: polygon) })
        var world = matrix_identity_float4x4; world.columns.0.x = -2; world.columns.3.x = 3
        app.scene.setEntityLocalMatrix(id,to: world)
        #expect(app.meshEditing.setMode(.face)); app.meshEditing.select([0])
        let overlay = try #require(app.makeGeometryOverlays(drawableSize: .init(width: 800,height: 600)).last)
        let area = overlay.triangles.reduce(Float(0)) { $0+simd_length(simd_cross($1.b-$1.a,$1.c-$1.a))*0.5 }
        #expect(overlay.triangles.count == 4 && abs(area-6) < 1e-5)
        #expect(overlay.triangles.allSatisfy { $0.a.x <= 3 && $0.b.x <= 3 && $0.c.x <= 3 })
        app.meshEditing.leave()
        #expect(app.geometryAuthoring.edit(entityID: id) { $0.source = .box(size: SIMD3(repeating: 1)) })
        #expect(app.meshEditing.setMode(.face)); app.meshEditing.select([1])
        #expect(app.meshEditing.beginInset())
        let inset = try #require(app.makeGeometryOverlays(drawableSize: .init(width: 800,height: 600)).last)
        #expect(inset.triangles.filter { $0.color.w > 0 }.count == 2 && inset.triangles.count == 20)
        #expect(app.meshEditing.cancelInset())
        #expect(app.makeGeometryOverlays(drawableSize: .init(width: 800,height: 600)).last?.triangles.count == 12)
    } }

    @Test("evaluated wireframe and object outlines share the depth-tested renderer")
    func modifierAndObject() throws { try withApp { app,id in
        #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
        #expect(app.meshEditing.setMode(.face)); app.meshEditing.select([1])
        let overlays = app.makeGeometryOverlays(drawableSize: .init(width: 800,height: 600))
        #expect(overlays.count == 2 && overlays[0].triangles.count == 48 && overlays[1].triangles.count == 12)
        #expect(overlays.allSatisfy { !$0.xray })
        app.meshEditing.leave()
        app.scene.tickScene()
        let object = app.makeGeometryOverlays(drawableSize: .init(width: 800,height: 600))
        #expect(object.count == 1 && !object[0].triangles.isEmpty && object[0].triangles.allSatisfy { $0.color.w == 0 })
    } }

    @Test("overlay changes invalidate an idle render gate without waiting for the heartbeat")
    func renderGate() {
        var gate = EditorViewportRenderGate()
        var signature = EditorViewportRenderGate.Signature(sceneRevision: 1,camera: .init(eye: SIMD3(0,0,5),target: .zero),
            drawableSize: .init(width: 800,height: 600),settingsGeneration: 1,jointPalettes: .init())
        func submit(_ time: Double) -> Bool {
            gate.shouldRender(signature: signature,forceContinuous: false,hasViewportInput: false,temporalEffectsActive: false,now: time)
        }
        #expect(submit(0)); #expect(submit(0.01)); #expect(!submit(0.02))
        var overlay = RenderGeometryOverlay(viewportSize: SIMD2(800,600))
        overlay.lines = [.init(.zero,SIMD3(1,0,0),color: SIMD4(1,0.5,0,1))]
        signature.geometryOverlays = [overlay]
        #expect(submit(0.03)); #expect(submit(0.04)); #expect(!submit(0.05))
        signature.geometryOverlays = []
        #expect(submit(0.06))
    }

    private func withApp(_ body: (EditorApplication,UInt64) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        let id = try #require(app.geometryAuthoring.create(.box))
        try body(app,id)
    }
}
