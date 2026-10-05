import AssetPipeline
import Foundation
import SIMDCompat

/// Immutable triangle BVH. Ray directions need not be normalized, so a ray
/// transformed into mesh space keeps its world-space distance parameter.
public struct MeshPickingSurface: Sendable {
    private struct Triangle: Sendable {
        var a: SIMD3<Float>; var b: SIMD3<Float>; var c: SIMD3<Float>
        var min: SIMD3<Float>; var max: SIMD3<Float>
    }
    private struct Node: Sendable {
        var min: SIMD3<Float>; var max: SIMD3<Float>
        var left: Int = -1; var right: Int = -1
        var triangles: [Int] = []
    }
    private var triangles: [Triangle] = []
    private var nodes: [Node] = []

    public init(positions: [SIMD3<Float>], indices: [UInt32]) {
        for i in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let ids = [Int(indices[i]), Int(indices[i + 1]), Int(indices[i + 2])]
            guard ids.allSatisfy({ positions.indices.contains($0) }) else { continue }
            let a = positions[ids[0]], b = positions[ids[1]], c = positions[ids[2]]
            guard [a, b, c].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { continue }
            triangles.append(Triangle(a: a, b: b, c: c,
                min: simd_min(a, simd_min(b, c)), max: simd_max(a, simd_max(b, c))))
        }
        if !triangles.isEmpty { _ = build(Array(triangles.indices)) }
    }

    private mutating func build(_ ids: [Int]) -> Int {
        let lo = ids.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, triangles[$1].min) }
        let hi = ids.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, triangles[$1].max) }
        let index = nodes.count
        nodes.append(Node(min: lo, max: hi))
        if ids.count <= 8 { nodes[index].triangles = ids; return index }
        let size = hi - lo
        let axis = size.x >= size.y && size.x >= size.z ? 0 : (size.y >= size.z ? 1 : 2)
        let sorted = ids.sorted { triangles[$0].min[axis] + triangles[$0].max[axis] < triangles[$1].min[axis] + triangles[$1].max[axis] }
        let middle = sorted.count / 2
        let left = build(Array(sorted[..<middle]))
        let right = build(Array(sorted[middle...]))
        nodes[index].left = left; nodes[index].right = right
        return index
    }

    public func hitDistance(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float = .greatestFiniteMagnitude) -> Float? {
        guard !nodes.isEmpty else { return nil }
        var nearest = maxDistance
        var hit = false
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            var near: Float = 0, far = nearest
            for axis in 0..<3 {
                if abs(direction[axis]) < 1e-12 {
                    if origin[axis] < node.min[axis] || origin[axis] > node.max[axis] { far = -1; break }
                } else {
                    let a = (node.min[axis] - origin[axis]) / direction[axis]
                    let b = (node.max[axis] - origin[axis]) / direction[axis]
                    near = Swift.max(near, Swift.min(a, b)); far = Swift.min(far, Swift.max(a, b))
                }
            }
            guard far >= near else { continue }
            if node.left >= 0 { stack.append(node.left); stack.append(node.right); continue }
            for id in node.triangles {
                let tri = triangles[id]
                let e1 = tri.b - tri.a, e2 = tri.c - tri.a
                let p = simd_cross(direction, e2)
                let determinant = simd_dot(e1, p)
                let tolerance = 1e-7 * simd_length(e1) * simd_length(p)
                guard abs(determinant) > tolerance else { continue }
                let inv = 1 / determinant, offset = origin - tri.a
                let u = simd_dot(offset, p) * inv
                guard u >= -1e-6 && u <= 1 + 1e-6 else { continue }
                let q = simd_cross(offset, e1), v = simd_dot(direction, q) * inv
                guard v >= -1e-6 && u + v <= 1 + 1e-6 else { continue }
                let t = simd_dot(e2, q) * inv
                if t > 1e-5 && t < nearest { nearest = t; hit = true }
            }
        }
        return hit ? nearest : nil
    }
}

public final class MeshPickingRegistry: @unchecked Sendable {
    public static let shared = MeshPickingRegistry()
    private let lock = NSLock()
    private var surfaces: [Int: MeshPickingSurface] = [:]
    private var assets: [Int: MeshAsset] = [:]
    private init() {}

    public func register(meshIndex: Int, mesh: MeshAsset) {
        let surface = MeshPickingSurface(positions: (0..<mesh.vertexCount).compactMap { mesh.position(at: $0) }, indices: mesh.indices)
        lock.lock(); surfaces[meshIndex] = surface; assets[meshIndex] = mesh; lock.unlock()
    }

    public func surface(for meshIndex: Int, jointMatrices: [simd_float4x4] = []) -> MeshPickingSurface? {
        lock.lock(); let cached = surfaces[meshIndex]; let cachedAsset = assets[meshIndex]; lock.unlock()
        if cached == nil {
            guard let mesh = AssetRegistry.shared.meshAsset(for: meshIndex)
                    ?? (meshIndex < 2 ? BuiltinMesh.cube() : nil) else { return nil }
            register(meshIndex: meshIndex, mesh: mesh)
            return surface(for: meshIndex, jointMatrices: jointMatrices)
        }
        guard !jointMatrices.isEmpty, let mesh = cachedAsset else { return cached }
        var positions: [SIMD3<Float>] = []
        for i in 0..<mesh.vertexCount {
            let offset = i * MeshAsset.vertexFloatCount
            let p = SIMD4<Float>(mesh.vertices[offset], mesh.vertices[offset + 1], mesh.vertices[offset + 2], 1)
            var skinned = SIMD4<Float>.zero
            var total: Float = 0
            for lane in 0..<4 {
                let joint = mesh.vertices[offset + MeshAsset.jointsFloatOffset + lane]
                let weight = mesh.vertices[offset + MeshAsset.weightsFloatOffset + lane]
                guard joint.isFinite, joint >= 0, joint < Float(jointMatrices.count), weight > 0 else { continue }
                skinned += (jointMatrices[Int(joint)] * p) * weight; total += weight
            }
            let value = total > 0.0001 ? skinned : p
            positions.append(SIMD3<Float>(value.x, value.y, value.z))
        }
        return MeshPickingSurface(positions: positions, indices: mesh.indices)
    }
}
