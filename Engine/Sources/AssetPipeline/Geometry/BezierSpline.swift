import Foundation
import SIMDCompat

public struct BezierControlPoint: Codable, Equatable, Sendable {
    public var position: SIMD3<Float>
    public var handleIn: SIMD3<Float>
    public var handleOut: SIMD3<Float>

    /// Handles are absolute positions in the same space as the control point.
    public init(position: SIMD3<Float>, handleIn: SIMD3<Float>, handleOut: SIMD3<Float>) {
        self.position = position; self.handleIn = handleIn; self.handleOut = handleOut
    }
}

public struct BezierSpline: Codable, Equatable, Sendable {
    public var points: [BezierControlPoint]
    public var closed: Bool

    public init(points: [BezierControlPoint], closed: Bool = false) {
        self.points = points; self.closed = closed
    }

    public func position(segment: Int, t: Float) throws -> SIMD3<Float> {
        let count = closed ? points.count : points.count - 1
        guard points.count >= 2, segment >= 0, segment < count, t.isFinite, (0...1).contains(t),
              points.allSatisfy({ geometryFinite($0.position) && geometryFinite($0.handleIn) && geometryFinite($0.handleOut) }) else {
            throw GeometryError.invalidParameter("Bezier segment/control points")
        }
        return sample(segment: segment, t: t)
    }

    private func sample(segment: Int, t: Float) -> SIMD3<Float> {
        let a = points[segment], b = points[(segment + 1) % points.count], u = 1 - t
        return a.position * (u*u*u) + a.handleOut * (3*u*u*t) + b.handleIn * (3*u*t*t) + b.position * (t*t*t)
    }

    /// Parallel-transported frames avoid the flips of a fixed world-up sweep.
    public func tube(radius: Float, radialSegments: Int = 12, samplesPerSegment: Int = 16,
                     capped: Bool = true, limits: GeometryLimits = .init()) throws -> PolygonMesh {
        guard points.count >= (closed ? 3 : 2), points.count <= limits.maxVertices,
              radius.isFinite, radius > 0, (3...256).contains(radialSegments),
              (1...4096).contains(samplesPerSegment) else { throw GeometryError.invalidParameter("tube parameters") }
        _ = try position(segment: 0, t: 0)
        let segments = closed ? points.count : points.count - 1
        guard segments <= (limits.maxVertices / radialSegments - 1) / samplesPerSegment else {
            throw GeometryError.budgetExceeded
        }
        let steps = segments * samplesPerSegment
        let ringCount = steps + (closed ? 0 : 1)
        try limits.check(vertices: ringCount * radialSegments,
                         corners: steps * radialSegments * 4 + (!closed && capped ? radialSegments * 2 : 0))
        var centers: [SIMD3<Float>] = []
        for i in 0..<ringCount {
            let segment = min(i / samplesPerSegment, segments - 1)
            let t = Float(i - segment * samplesPerSegment) / Float(samplesPerSegment)
            centers.append(sample(segment: segment, t: t))
        }
        guard centers.allSatisfy(geometryFinite) else { throw GeometryError.invalidMesh("non-finite curve sample") }
        var tangents: [SIMD3<Float>] = []
        for i in centers.indices {
            let prev = centers[closed ? (i + ringCount - 1) % ringCount : max(0, i - 1)]
            let next = centers[closed ? (i + 1) % ringCount : min(ringCount - 1, i + 1)]
            guard simd_length_squared(next - centers[i]) > 1e-16 || (!closed && i == ringCount - 1),
                  simd_length_squared(next - prev) > 1e-16 else {
                throw GeometryError.invalidMesh("coincident samples or cusp in curve")
            }
            tangents.append(geometryUnit(next - prev))
        }
        func transport(_ normal: SIMD3<Float>, from a: SIMD3<Float>, to b: SIMD3<Float>) -> SIMD3<Float> {
            let axis = simd_cross(a, b), cosine = simd_dot(a, b)
            if cosine < -0.9999 { return geometryUnit(normal - b * simd_dot(normal, b)) }
            let rotated = normal + simd_cross(axis, normal) + simd_cross(axis, simd_cross(axis, normal)) / max(1 + cosine, 1e-6)
            return geometryUnit(rotated - b * simd_dot(rotated, b))
        }
        let reference = abs(tangents[0].y) < 0.9 ? SIMD3<Float>(0,1,0) : SIMD3<Float>(1,0,0)
        var normals = [geometryUnit(simd_cross(reference, tangents[0]))]
        for i in 1..<ringCount { normals.append(transport(normals[i - 1], from: tangents[i - 1], to: tangents[i])) }
        if closed {
            let end = transport(normals[ringCount - 1], from: tangents[ringCount - 1], to: tangents[0])
            let correction = atan2(simd_dot(tangents[0], simd_cross(end, normals[0])), simd_dot(end, normals[0]))
            for i in normals.indices {
                let angle = correction * Float(i) / Float(ringCount)
                normals[i] = normals[i] * cos(angle) + simd_cross(tangents[i], normals[i]) * sin(angle)
            }
        }
        var positions: [SIMD3<Float>] = [], faces: [PolygonFace] = []
        for i in centers.indices {
            let binormal = simd_cross(tangents[i], normals[i])
            for j in 0..<radialSegments {
                let angle = 2 * Float.pi * Float(j) / Float(radialSegments)
                positions.append(centers[i] + radius * (normals[i] * cos(angle) + binormal * sin(angle)))
            }
        }
        for i in 0..<steps {
            let next = (i + 1) % ringCount
            for j in 0..<radialSegments {
                let k = (j + 1) % radialSegments
                let u = Float(j) / Float(radialSegments), v = Float(i) / Float(steps)
                let un = Float(j + 1) / Float(radialSegments), vn = Float(i + 1) / Float(steps)
                faces.append(PolygonFace([i*radialSegments+j, i*radialSegments+k, next*radialSegments+k, next*radialSegments+j],
                    uvs: [SIMD2(u,v), SIMD2(un,v), SIMD2(un,vn), SIMD2(u,vn)]))
            }
        }
        if !closed && capped {
            let capUVs = (0..<radialSegments).map { j -> SIMD2<Float> in
                let a = 2 * Float.pi * Float(j) / Float(radialSegments)
                return SIMD2(0.5 + 0.5*cos(a), 0.5 + 0.5*sin(a))
            }
            faces.append(PolygonFace(Array((0..<radialSegments).reversed()), uvs: Array(capUVs.reversed())))
            faces.append(PolygonFace((0..<radialSegments).map { (ringCount-1)*radialSegments+$0 }, uvs: capUVs))
        }
        return PolygonMesh(positions: positions, faces: faces)
    }
}
