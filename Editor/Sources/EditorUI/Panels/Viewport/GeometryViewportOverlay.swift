import AssetPipeline
import EditorCore
import CoveUI
import CoveUIRuntime
import SceneRuntime
import SIMDCompat

enum GeometryViewportOverlay {
    /// Outline the surface instead of presenting its bounding box as topology.
    static func drawSelection(app: EditorApplication, entityID: UInt64, list: DrawList,
                              frame: ViewportScreenFrame) -> Bool {
        guard let picker = app.geometryAuthoring.viewportPicker(for: entityID),
              let projection = EditorViewportProjection(camera: app.scene.currentRenderCamera(), frame: frame) else { return false }
        let camera = app.scene.currentRenderCamera()
        var sides: [PolygonMeshEdge: [Bool]] = [:]
        for face in picker.mesh.faces {
            let origin = picker.positions[face.vertices[0]]
            var normal = SIMD3<Float>.zero
            for i in face.vertices.indices {
                normal += simd_cross(picker.positions[face.vertices[i]]-origin,
                                     picker.positions[face.vertices[(i+1)%face.vertices.count]]-origin)
            }
            let view = camera.projection == .orthographic ? camera.eye-camera.target : camera.eye-origin
            let front = simd_dot(normal,view) >= 0
            for i in face.vertices.indices {
                sides[.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count]),default: []].append(front)
            }
        }
        let color = Color(r: 1,g: 0.65,b: 0.18,a: 1)
        for edge in picker.edges {
            guard let facing = sides[edge], facing.count == 1 || Set(facing).count > 1 else { continue }
            let a = picker.positions[edge.a], b = picker.positions[edge.b]
            guard picker.isVisible((a+b)*0.5,projection: projection,xray: false),
                  let pa = projection.project(a), let pb = projection.project(b) else { continue }
            list.addLine(fromX: pa.x,fromY: pa.y,toX: pb.x,toY: pb.y,thickness: 2,color: color)
        }
        return true
    }

    static func drawEvaluated(app: EditorApplication, entityID: UInt64, list: DrawList,
                              frame: ViewportScreenFrame) {
        guard let picker = app.geometryAuthoring.viewportPicker(for: entityID),
              let projection = EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: frame) else { return }
        for edge in picker.edges {
            let a = picker.positions[edge.a], b = picker.positions[edge.b]
            guard picker.isVisible((a+b)*0.5,projection: projection,xray: false),
                  let pa = projection.project(a), let pb = projection.project(b) else { continue }
            list.addLine(fromX: pa.x,fromY: pa.y,toX: pb.x,toY: pb.y,thickness: 1,
                         color: Color(r: 0.35,g: 0.7,b: 0.78,a: 0.55))
        }
    }
}
