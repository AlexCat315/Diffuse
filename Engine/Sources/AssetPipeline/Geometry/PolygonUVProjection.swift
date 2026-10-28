import SIMDCompat

/// Affine surface coordinates preserve UV interpolation when coplanar
/// topology changes. A seam stays local to each face's own projection.
struct PolygonUVProjection {
    private let origin: SIMD3<Double>
    private let e1: SIMD3<Double>
    private let e2: SIMD3<Double>
    private let d11: Double
    private let d12: Double
    private let d22: Double
    private let determinant: Double
    private let uv: SIMD2<Float>
    private let du: SIMD2<Float>
    private let dv: SIMD2<Float>

    init(positions: [SIMD3<Float>],uvs: [SIMD2<Float>]) throws {
        guard positions.count >= 3,positions.count == uvs.count else { throw GeometryError.invalidMesh("invalid UV projection") }
        let points = positions.map { SIMD3<Double>($0) }
        origin = points[0]
        let a = points[0]
        func lengthSquared(_ p: SIMD3<Double>) -> Double { simd_dot(p,p) }
        let b = points.indices.max { lengthSquared(points[$0]-a) < lengthSquared(points[$1]-a) }!
        let axis = points[b]-a
        func crossSquared(_ p: SIMD3<Double>) -> Double {
            lengthSquared(SIMD3(axis.y*p.z-axis.z*p.y,axis.z*p.x-axis.x*p.z,axis.x*p.y-axis.y*p.x))
        }
        let c = points.indices.max { crossSquared(points[$0]-a) < crossSquared(points[$1]-a) }!
        e1 = axis; e2 = points[c]-a
        d11 = simd_dot(e1,e1); d12 = simd_dot(e1,e2); d22 = simd_dot(e2,e2)
        determinant = d11*d22-d12*d12
        guard determinant.isFinite,determinant > max(1e-30,d11*d22*1e-12) else { throw GeometryError.invalidMesh("degenerate UV projection") }
        uv = uvs[0]; du = uvs[b]-uv; dv = uvs[c]-uv
        let tolerance = max(1e-5,uvs.reduce(Float(0)) { max($0,simd_length($1-uvs[0])) }*1e-5)
        guard positions.indices.allSatisfy({ simd_distance(project(positions[$0]),uvs[$0]) <= tolerance }) else {
            throw GeometryError.invalidMesh("topology edit would change non-affine UV interpolation")
        }
    }

    func project(_ point: SIMD3<Float>) -> SIMD2<Float> {
        let offset = SIMD3<Double>(point)-origin, u = simd_dot(offset,e1), v = simd_dot(offset,e2)
        return uv+du*Float((u*d22-v*d12)/determinant)+dv*Float((v*d11-u*d12)/determinant)
    }
}
