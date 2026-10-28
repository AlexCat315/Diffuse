import Foundation
import SIMDCompat

public enum GeometryShading: String, Codable, Sendable { case flat, smooth }

public struct GeometryEvaluation: Sendable {
    public let controlMesh: PolygonMesh
    public let mesh: MeshAsset
    public let topologySlice: MeshTopologySlice
}

extension PolygonMesh {
    /// Produces the existing 24-float vertex layout, submeshes, and topology map.
    public func bake(name: String, shading: GeometryShading = .flat,
                     materials: [MeshMaterial] = [.fallback], limits: GeometryLimits = .init()) throws -> GeometryEvaluation {
        try validate(limits: limits)
        guard !materials.isEmpty, faces.allSatisfy({ materials.indices.contains($0.materialIndex) }) else {
            throw GeometryError.invalidMesh("face references a missing material slot")
        }
        let cornerCount = faces.reduce(0) { $0 + $1.vertices.count }
        // GPU vertices split at every face corner, independent of control count.
        guard cornerCount <= limits.maxVertices else { throw GeometryError.budgetExceeded }
        var smoothNormals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        let faceNormals = faces.map { geometryNormal($0, positions: positions) }
        if shading == .smooth {
            for (i, face) in faces.enumerated() {
                for vertex in face.vertices { smoothNormals[vertex] += faceNormals[i] }
            }
        }
        var vertices: [Float] = [], indices: [UInt32] = [], remap: [UInt32] = []
        var parts: [MeshSubmesh] = []
        vertices.reserveCapacity(cornerCount * MeshAsset.vertexFloatCount)
        for (faceIndex, face) in faces.enumerated() {
            let triangles = try triangulate(face, positions: positions)
            let normal = geometryUnit(faceNormals[faceIndex])
            let axis = abs(normal.x) > abs(normal.y) && abs(normal.x) > abs(normal.z) ? 0 : (abs(normal.y) > abs(normal.z) ? 1 : 2)
            let uvs = face.uvs ?? face.vertices.map { vertex -> SIMD2<Float> in
                let p = positions[vertex]
                switch axis { case 0: return SIMD2(p.y,p.z); case 1: return SIMD2(p.z,p.x); default: return SIMD2(p.x,p.y) }
            }
            var tangents = [SIMD3<Float>](repeating: .zero, count: face.vertices.count)
            var bitangents = tangents
            for i in stride(from: 0, to: triangles.count, by: 3) {
                let a = triangles[i], b = triangles[i+1], c = triangles[i+2]
                let e1 = positions[face.vertices[b]] - positions[face.vertices[a]]
                let e2 = positions[face.vertices[c]] - positions[face.vertices[a]]
                let uv1 = uvs[b] - uvs[a], uv2 = uvs[c] - uvs[a]
                let determinant = uv1.x*uv2.y - uv1.y*uv2.x
                if abs(determinant) > 1e-12 {
                    let t = (e1*uv2.y - e2*uv1.y) / determinant
                    let b = (e2*uv1.x - e1*uv2.x) / determinant
                    for corner in [triangles[i], triangles[i+1], triangles[i+2]] {
                        tangents[corner] += t; bitangents[corner] += b
                    }
                }
            }
            let base = UInt32(remap.count)
            for i in face.vertices.indices {
                let vertex = face.vertices[i]
                let n = shading == .flat ? normal : geometryUnit(smoothNormals[vertex], fallback: normal)
                let reference = abs(n.y) < 0.9 ? SIMD3<Float>(0,1,0) : SIMD3<Float>(1,0,0)
                let tangent = geometryUnit(tangents[i] - n*simd_dot(n,tangents[i]), fallback: geometryUnit(simd_cross(reference,n)))
                let sign: Float = simd_dot(simd_cross(n,tangent),bitangents[i]) < 0 ? -1 : 1
                MeshAsset.appendVertex(to: &vertices, position: positions[vertex], normal: n, uv: uvs[i],
                    tangent: SIMD4(tangent.x,tangent.y,tangent.z,sign), materialIndex: Float(face.materialIndex))
                remap.append(UInt32(vertex))
            }
            let start = UInt32(indices.count)
            indices += triangles.map { base + UInt32($0) }
            if let previous = parts.last, previous.materialIndex == face.materialIndex {
                parts[parts.count-1] = MeshSubmesh(indexStart: previous.indexStart,
                    indexCount: previous.indexCount + UInt32(triangles.count), materialIndex: face.materialIndex)
            } else {
                parts.append(MeshSubmesh(indexStart: start, indexCount: UInt32(triangles.count), materialIndex: face.materialIndex))
            }
        }
        guard vertices.allSatisfy(\.isFinite) else { throw GeometryError.invalidMesh("non-finite baked vertex") }
        return GeometryEvaluation(controlMesh: self,
            mesh: MeshAsset(name: name, vertices: vertices, indices: indices, materials: materials, submeshes: parts),
            topologySlice: MeshTopologySlice(positions: positions, triangleIndices: indices, indexRemap: remap))
    }
}
