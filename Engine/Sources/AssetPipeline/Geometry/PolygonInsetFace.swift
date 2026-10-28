import SIMDCompat

struct PolygonInsetFace {
    let origin: SIMD3<Float>
    let x: SIMD3<Float>
    let y: SIMD3<Float>
    let points: [SIMD2<Double>]
    let inward: [SIMD2<Double>]
    let uv: PolygonUVProjection?
    let safeDistance: Float

    init(face: PolygonFace,positions: [SIMD3<Float>]) throws {
        _ = try triangulate(face,positions: positions)
        origin = positions[face.vertices[0]]
        let normal = geometryUnit(geometryNormal(face,positions: positions))
        let edge = positions[face.vertices[1]]-origin
        guard simd_length_squared(edge) > 0 else { throw GeometryError.invalidMesh("inset has a zero-length edge") }
        x = geometryUnit(edge); y = simd_cross(normal,x)
        let start = origin, axisX = x, axisY = y
        let vertices = face.vertices.map { positions[$0] }
        let extent = vertices.reduce(Float(0)) { max($0,simd_length($1-start)) }
        guard vertices.allSatisfy({ abs(simd_dot($0-start,normal)) <= max(1e-6,extent*1e-5) }) else {
            throw GeometryError.invalidMesh("inset requires planar faces")
        }
        let projected = vertices.map { let p = $0-start; return SIMD2(Double(simd_dot(p,axisX)),Double(simd_dot(p,axisY))) }
        points = projected
        var normals: [SIMD2<Double>] = []
        for i in projected.indices {
            let edge = projected[(i+1)%projected.count]-projected[i], length = simd_dot(edge,edge).squareRoot()
            guard length.isFinite,length > 0 else { throw GeometryError.invalidMesh("inset has a zero-length edge") }
            normals.append(SIMD2(-edge.y,edge.x)/length)
        }
        for i in projected.indices {
            let a = normals[(i+projected.count-1)%projected.count], b = normals[i]
            guard a.x*b.y-a.y*b.x >= -1e-10, 1+simd_dot(a,b) > 1e-8 else {
                throw GeometryError.invalidMesh("inset currently requires convex faces")
            }
        }
        inward = normals
        let center = projected.reduce(SIMD2<Double>.zero) { $0+$1/Double(projected.count) }
        let radius = projected.indices.map { simd_dot(center-projected[$0],normals[$0]) }.min()!
        guard radius.isFinite,radius > 0 else { throw GeometryError.invalidMesh("degenerate inset face") }
        // A short chamfer can disappear before the polygon reaches its center.
        // Bound every miter against every offset edge, including distant edges.
        var maximum = radius
        for i in projected.indices {
            let a = normals[(i+projected.count-1)%projected.count], b = normals[i]
            let velocity = (a+b)/(1+simd_dot(a,b))
            for j in projected.indices where j != i && j != (i+projected.count-1)%projected.count {
                let closing = 1-simd_dot(velocity,normals[j])
                if closing > 1e-10 { maximum = min(maximum,simd_dot(projected[i]-projected[j],normals[j])/closing) }
            }
        }
        safeDistance = Float(maximum*0.25)
        guard safeDistance.isFinite,safeDistance > 0 else { throw GeometryError.invalidMesh("degenerate inset face") }
        uv = try face.uvs.map { try PolygonUVProjection(positions: vertices,uvs: $0) }
    }

    func inset(by distance: Float) throws -> [SIMD3<Float>] {
        let width = Double(distance), tolerance = max(1e-12,width*1e-6)
        let result = points.indices.map { i in
            let a = inward[(i+points.count-1)%points.count], b = inward[i]
            return points[i]+(a+b)*(width/(1+simd_dot(a,b)))
        }
        guard result.allSatisfy({ point in points.indices.allSatisfy { simd_dot(point-points[$0],inward[$0]) >= width-tolerance } }) else {
            throw GeometryError.invalidParameter("inset width collapses the face")
        }
        return result.map { origin+x*Float($0.x)+y*Float($0.y) }
    }
}
