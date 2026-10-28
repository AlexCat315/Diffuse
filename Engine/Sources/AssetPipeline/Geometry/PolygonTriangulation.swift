import Foundation
import SIMDCompat

/// Ear clipping on the dominant projection handles concave simple polygons.
/// Returns corner indices so UV seams and material boundaries survive.
func triangulate(_ face: PolygonFace, positions: [SIMD3<Float>]) throws -> [Int] {
    let normal = geometryNormal(face, positions: positions)
    guard geometryFinite(normal), simd_length_squared(normal) > 1e-20 else {
        throw GeometryError.invalidMesh("degenerate polygon")
    }
    let n = SIMD3(abs(normal.x), abs(normal.y), abs(normal.z))
    let axis = n.x > n.y && n.x > n.z ? 0 : (n.y > n.z ? 1 : 2)
    let origin = positions[face.vertices[0]]
    let points: [SIMD2<Double>] = face.vertices.map {
        let p = positions[$0] - origin
        switch axis {
        case 0: return SIMD2(Double(p.y), Double(p.z))
        case 1: return SIMD2(Double(p.z), Double(p.x))
        default: return SIMD2(Double(p.x), Double(p.y))
        }
    }
    func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    let extent = points.reduce(0.0) { max($0, max(abs($1.x), abs($1.y))) }
    let epsilon = max(extent * extent * 1e-12, 1e-24)
    let distanceEpsilon = max(extent * 1e-12, 1e-15)
    func onSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
        p.x >= min(a.x,b.x) - distanceEpsilon && p.x <= max(a.x,b.x) + distanceEpsilon &&
            p.y >= min(a.y,b.y) - distanceEpsilon && p.y <= max(a.y,b.y) + distanceEpsilon
    }
    let area = points.indices.reduce(0.0) { $0 + cross(.zero, points[$1], points[($1 + 1) % points.count]) }
    guard abs(area) > epsilon else { throw GeometryError.invalidMesh("zero-area polygon") }
    let sign = area > 0 ? 1.0 : -1.0
    // Reject crossing edges explicitly; an ear alone does not prove simplicity.
    for i in points.indices {
        let nextI = (i + 1) % points.count
        for j in points.indices where j > i {
            let nextJ = (j + 1) % points.count
            if nextI == j || nextJ == i { continue }
            let a = cross(points[i], points[nextI], points[j])
            let b = cross(points[i], points[nextI], points[nextJ])
            let c = cross(points[j], points[nextJ], points[i])
            let d = cross(points[j], points[nextJ], points[nextI])
            let crossing = ((a > epsilon && b < -epsilon) || (a < -epsilon && b > epsilon)) &&
                ((c > epsilon && d < -epsilon) || (c < -epsilon && d > epsilon))
            let touching = (abs(a) <= epsilon && onSegment(points[j],points[i],points[nextI])) ||
                (abs(b) <= epsilon && onSegment(points[nextJ],points[i],points[nextI])) ||
                (abs(c) <= epsilon && onSegment(points[i],points[j],points[nextJ])) ||
                (abs(d) <= epsilon && onSegment(points[nextI],points[j],points[nextJ]))
            if crossing || touching {
                throw GeometryError.invalidMesh("self-intersecting polygon")
            }
        }
    }
    var remaining = Array(points.indices)
    var result: [Int] = []
    while remaining.count > 3 {
        var found = false
        for i in remaining.indices {
            let a = remaining[(i + remaining.count - 1) % remaining.count]
            let b = remaining[i], c = remaining[(i + 1) % remaining.count]
            guard sign * cross(points[a], points[b], points[c]) > epsilon else { continue }
            let contains = remaining.contains { p in
                p != a && p != b && p != c &&
                    sign * cross(points[a], points[b], points[p]) >= -epsilon &&
                    sign * cross(points[b], points[c], points[p]) >= -epsilon &&
                    sign * cross(points[c], points[a], points[p]) >= -epsilon
            }
            if contains { continue }
            result += [a, b, c]
            remaining.remove(at: i)
            found = true
            break
        }
        guard found else { throw GeometryError.invalidMesh("polygon cannot be triangulated") }
    }
    guard sign * cross(points[remaining[0]], points[remaining[1]], points[remaining[2]]) > epsilon else {
        throw GeometryError.invalidMesh("degenerate polygon triangle")
    }
    return result + remaining
}
