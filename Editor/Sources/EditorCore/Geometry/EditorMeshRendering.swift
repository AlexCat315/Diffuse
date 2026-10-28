import AssetPipeline
import RenderBackend
import SceneRuntime
import SIMDCompat

extension EditorMeshEditing {
    func renderOverlay(viewportSize: SIMD2<Float>) -> RenderGeometryOverlay? {
        guard isEditing, let picker = picker() else { return nil }
        let active = SIMD4<Float>(1,0.58,0.12,1), inactive = SIMD4<Float>(0.65,0.72,0.8,0.85)
        let vertices = selectedVertices
        var selectedEdges = Set<PolygonMeshEdge>()
        if mode == .face {
            for index in selection where picker.mesh.faces.indices.contains(index) {
                let face = picker.mesh.faces[index]
                for i in face.vertices.indices { selectedEdges.insert(.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count])) }
            }
        }
        if mode == .edge { selectedEdges = Set(selection.filter { picker.edges.indices.contains($0) }.map { picker.edges[$0] }) }
        let overlay = picker.surfaceOverlay(viewport: viewportSize,xray: xray,fill: { face in
            mode == .face && selection.contains(face) ? SIMD4(1,0.48,0.08,xray ? 0.16 : 0.27) : .zero
        },style: { edge in
            let selected = mode == .vertex ? vertices.contains(edge.a) && vertices.contains(edge.b) : selectedEdges.contains(edge)
            return (selected ? active : inactive,selected ? 2 : 1)
        })
        return overlay
    }
}

extension EditorApplication {
    func makeGeometryOverlays(drawableSize: RenderDrawableSize) -> [RenderGeometryOverlay] {
        guard store.viewportMode == .scene else { return [] }
        meshEditing.synchronize()
        let viewport = EditorViewportDropTarget.frame.map { SIMD2($0.width,$0.height) }
            ?? SIMD2(Float(drawableSize.width),Float(drawableSize.height))
        guard viewport.x.isFinite,viewport.y.isFinite,viewport.x > 0,viewport.y > 0 else { return [] }
        if let overlay = meshEditing.renderOverlay(viewportSize: viewport) {
            var result: [RenderGeometryOverlay] = []
            if meshEditing.showsEvaluatedWireframe,meshEditing.hasModifiers,let id = meshEditing.entityID,
               let picker = geometryAuthoring.viewportPicker(for: id) {
                let wire = picker.surfaceOverlay(viewport: viewport) { _ in (SIMD4(0.35,0.7,0.78,0.55),1) }
                result.append(wire)
            }
            result.append(overlay)
            return result
        }
        guard store.state.viewport.shadingMode != .wireframe else { return [] }
        var result = RenderGeometryOverlay(viewportSize: viewport)
        let selected = store.selectedEntityIDs.isEmpty ? Set(store.selectedEntityID.map { [$0] } ?? []) : store.selectedEntityIDs
        for bounds in scene.viewportWorldBounds() where selected.contains(bounds.entityID) {
            guard let picker = geometryAuthoring.viewportPicker(for: bounds.entityID) else { continue }
            let contour = silhouette(picker: picker,camera: scene.currentRenderCamera())
            result.triangles += picker.surfaceOverlay(viewport: viewport) { contour.contains($0) ? (SIMD4(1,0.65,0.18,1),2) : nil }.triangles
        }
        return result.isEmpty ? [] : [result]
    }

    private func silhouette(picker: EditorMeshPicker,camera: RenderCamera) -> Set<PolygonMeshEdge> {
        var sides: [PolygonMeshEdge: Set<Bool>] = [:], uses: [PolygonMeshEdge: Int] = [:]
        for face in picker.mesh.faces {
            let origin = picker.positions[face.vertices[0]]
            var normal = SIMD3<Float>.zero
            for i in face.vertices.indices {
                normal += simd_cross(picker.positions[face.vertices[i]]-origin,picker.positions[face.vertices[(i+1)%face.vertices.count]]-origin)
            }
            let view = camera.projection == .orthographic ? camera.eye-camera.target : camera.eye-origin
            for i in face.vertices.indices {
                let edge = PolygonMeshEdge(face.vertices[i],face.vertices[(i+1)%face.vertices.count])
                sides[edge,default: []].insert(simd_dot(normal,view) >= 0); uses[edge,default: 0] += 1
            }
        }
        return Set(picker.edges.filter { uses[$0] == 1 || sides[$0]?.count == 2 })
    }
}
