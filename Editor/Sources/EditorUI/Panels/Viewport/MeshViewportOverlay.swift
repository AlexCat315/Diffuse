import EditorCore
import CoveUI
import CoveUIRuntime
import SIMDCompat

enum MeshViewportOverlay {
    static func draw(app: EditorApplication, list: DrawList, frame: ViewportScreenFrame) {
        let model = app.meshEditing
        guard model.isEditing else { return }
        let inactive = Color(r: 0.65,g: 0.72,b: 0.8,a: 0.85)
        if let picker = model.picker(),let projection = EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: frame) {
            // Handles are point annotations. Keep their screen-sized glyphs
            // whole after a point visibility test; surfaces and wires use GPU depth.
            let positions = model.mode == .vertex ? picker.positions : (model.mode == .face ? picker.mesh.faces.map { face in
                face.vertices.reduce(SIMD3<Float>.zero) { $0+picker.positions[$1]/Float(face.vertices.count) }
            } : [])
            for (i,p) in positions.enumerated() where picker.isVisible(p,projection: projection,xray: model.xray) {
                guard let screen = projection.project(p) else { continue }
                let selected = model.selection.contains(i), radius: Float = selected ? 4 : 2.5
                list.addRect(UIRect(x: screen.x-radius,y: screen.y-radius,width: radius*2,height: radius*2),
                    color: selected ? Color(r: 1,g: 0.58,b: 0.12,a: 1) : inactive)
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

}
