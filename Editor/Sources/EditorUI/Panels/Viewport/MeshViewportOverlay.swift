import AssetPipeline
import EditorCore
import CoveUI
import CoveUIRuntime
import Foundation
import SIMDCompat

enum MeshViewportOverlay {
    static func draw(app: EditorApplication, list: DrawList, frame: ViewportScreenFrame) {
        let model = app.meshEditing
        guard model.isEditing, let picker = model.picker(),
              let projection = EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: frame) else { return }
        let active = Color(r: 1,g: 0.58,b: 0.12,a: 1)
        let inactive = Color(r: 0.65,g: 0.72,b: 0.8,a: 0.85)
        let selectedVertices = model.selectedVertices
        var faceEdges = Set<PolygonMeshEdge>()
        if model.mode == .face {
            for index in model.selection where picker.mesh.faces.indices.contains(index) {
                let vertices = picker.mesh.faces[index].vertices
                for i in vertices.indices { faceEdges.insert(.init(vertices[i],vertices[(i+1)%vertices.count])) }
            }
        }
        for (index,edge) in picker.edges.enumerated() {
            let a = picker.positions[edge.a], b = picker.positions[edge.b]
            guard picker.isVisible((a+b)*0.5,projection: projection,xray: model.xray),
                  let pa = projection.project(a), let pb = projection.project(b) else { continue }
            let selected = model.mode == .face ? faceEdges.contains(edge)
                : (model.mode == .edge ? model.selection.contains(index) : selectedVertices.contains(edge.a) && selectedVertices.contains(edge.b))
            list.addLine(fromX: pa.x,fromY: pa.y,toX: pb.x,toY: pb.y,thickness: selected ? 2 : 1,color: selected ? active : inactive)
        }
        if model.mode == .vertex {
            for (index,point) in picker.positions.enumerated() where picker.isVisible(point,projection: projection,xray: model.xray) {
                guard let screen = projection.project(point) else { continue }
                marker(list,screen.x,screen.y,selected: model.selection.contains(index),active: active,inactive: inactive)
            }
        } else if model.mode == .face {
            for (index,face) in picker.mesh.faces.enumerated() {
                let center = face.vertices.reduce(SIMD3<Float>.zero) { $0+picker.positions[$1]/Float(face.vertices.count) }
                guard picker.isVisible(center,projection: projection,xray: model.xray), let screen = projection.project(center) else { continue }
                marker(list,screen.x,screen.y,selected: model.selection.contains(index),active: active,inactive: inactive)
            }
        }
        if let rect = model.pointer.marquee {
            list.addRect(rect,color: Color(r: 0.25,g: 0.55,b: 1,a: 0.12))
            let points: [(Float,Float)] = [(rect.x,rect.y),(rect.x+rect.width,rect.y),(rect.x+rect.width,rect.y+rect.height),(rect.x,rect.y+rect.height)]
            for i in points.indices {
                let a = points[i], b = points[(i+1)%points.count]
                list.addLine(fromX: a.0,fromY: a.1,toX: b.0,toY: b.1,thickness: 1,color: inactive)
            }
        }
    }

    private static func marker(_ list: DrawList, _ x: Float, _ y: Float, selected: Bool, active: Color, inactive: Color) {
        let radius: Float = selected ? 4 : 2.5
        list.addRect(UIRect(x: x-radius,y: y-radius,width: radius*2,height: radius*2),color: selected ? active : inactive)
    }
}
