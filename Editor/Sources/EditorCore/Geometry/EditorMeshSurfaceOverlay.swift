import AssetPipeline
import SceneRuntime
import SIMDCompat

extension EditorMeshPicker {
    /// Surface-supported wires share depth interpolation with the real faces.
    /// Per-triangle masks suppress triangulation diagonals, including concave n-gons.
    func surfaceOverlay(viewport: SIMD2<Float>,xray: Bool = false,fill: (Int) -> SIMD4<Float> = { _ in .zero },
                        style: (PolygonMeshEdge) -> (color: SIMD4<Float>,width: Float)?) -> RenderGeometryOverlay {
        var result = RenderGeometryOverlay(viewportSize: viewport,xray: xray)
        let boundaries = mesh.faces.map { face in
            Set(face.vertices.indices.map { PolygonMeshEdge(face.vertices[$0],face.vertices[($0+1)%face.vertices.count]) })
        }
        forEachTriangle { face,indices in
            let edges = [PolygonMeshEdge(Int(indices.y),Int(indices.z)),.init(Int(indices.z),Int(indices.x)),.init(Int(indices.x),Int(indices.y))]
            let styles = edges.map { boundaries[face].contains($0) ? style($0) : nil }
            result.triangles.append(.init(positions[Int(indices.x)],positions[Int(indices.y)],positions[Int(indices.z)],color: fill(face),
                edgeWidths: SIMD3(styles[0]?.width ?? 0,styles[1]?.width ?? 0,styles[2]?.width ?? 0),
                edgeA: styles[0]?.color ?? .zero,edgeB: styles[1]?.color ?? .zero,edgeC: styles[2]?.color ?? .zero))
        }
        return result
    }
}
