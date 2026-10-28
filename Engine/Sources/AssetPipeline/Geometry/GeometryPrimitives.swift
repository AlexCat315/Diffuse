import Foundation
import SIMDCompat

public enum GeometryPrimitives {
    public static func box(size: SIMD3<Float> = SIMD3(repeating: 1)) throws -> PolygonMesh {
        guard geometryFinite(size), size.x > 0, size.y > 0, size.z > 0 else {
            throw GeometryError.invalidParameter("box size")
        }
        let points: [SIMD3<Float>] = [SIMD3(-1,-1,-1), SIMD3(1,-1,-1), SIMD3(1,1,-1), SIMD3(-1,1,-1),
            SIMD3(-1,-1,1), SIMD3(1,-1,1), SIMD3(1,1,1), SIMD3(-1,1,1)]
        let uv: [SIMD2<Float>] = [SIMD2(0,0), SIMD2(1,0), SIMD2(1,1), SIMD2(0,1)]
        return PolygonMesh(positions: points.map { $0 * size * 0.5 }, faces:
            [[0,3,2,1], [4,5,6,7], [0,1,5,4], [3,7,6,2], [0,4,7,3], [1,2,6,5]].map { PolygonFace($0, uvs: uv) })
    }

    /// XZ grid with upward-facing quads and normalized UVs.
    public static func grid(size: SIMD2<Float>, segments: SIMD2<Int>,
                            limits: GeometryLimits = .init()) throws -> PolygonMesh {
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
              segments.x > 0, segments.y > 0,
              segments.x < limits.maxVertices, segments.y < limits.maxVertices else {
            throw GeometryError.invalidParameter("grid size/segments")
        }
        guard segments.x + 1 <= limits.maxVertices / (segments.y + 1),
              segments.x <= limits.maxFaceCorners / 4 / segments.y else { throw GeometryError.budgetExceeded }
        var points: [SIMD3<Float>] = []
        var faces: [PolygonFace] = []
        for y in 0...segments.y {
            for x in 0...segments.x {
                points.append(SIMD3((Float(x) / Float(segments.x) - 0.5) * size.x,
                                    0, (Float(y) / Float(segments.y) - 0.5) * size.y))
            }
        }
        for y in 0..<segments.y {
            for x in 0..<segments.x {
                let a = y * (segments.x + 1) + x, b = a + segments.x + 1
                let u0 = Float(x) / Float(segments.x), u1 = Float(x + 1) / Float(segments.x)
                let v0 = Float(y) / Float(segments.y), v1 = Float(y + 1) / Float(segments.y)
                faces.append(PolygonFace([a, b, b + 1, a + 1],
                    uvs: [SIMD2(u0,v0), SIMD2(u0,v1), SIMD2(u1,v1), SIMD2(u1,v0)]))
            }
        }
        return PolygonMesh(positions: points, faces: faces)
    }
}
