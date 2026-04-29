import AssetPipeline
import Foundation
import simd

public struct MeshWireframeEdge: Sendable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>

    public init(a: SIMD3<Float>, b: SIMD3<Float>) {
        self.a = a
        self.b = b
    }
}

/// 可注册的线框拓扑描述。
/// - `positions`：顶点位置池（local space）。
/// - `triangleIndices`：按三角形组织的索引（3 的倍数）。
/// - `indexRemap`：可选。用于 glTF 多子网格拆分等场景，把局部 primitive
///   的索引重映射到共享位置池。
public struct MeshWireframeTopology: Sendable {
    public var positions: [SIMD3<Float>]
    public var triangleIndices: [UInt32]
    public var indexRemap: [UInt32]?

    public init(positions: [SIMD3<Float>],
                triangleIndices: [UInt32],
                indexRemap: [UInt32]? = nil) {
        self.positions = positions
        self.triangleIndices = triangleIndices
        self.indexRemap = indexRemap
    }
}

/// 进程级 mesh 线框拓扑缓存。把 mesh 的三角面去重为边线，
/// 编辑器可按 meshIndex 读取真实线框而不是 AABB 近似。
public final class MeshWireframeRegistry: @unchecked Sendable {
    public static let shared = MeshWireframeRegistry()

    private let lock = NSLock()
    private var storage: [Int: [MeshWireframeEdge]] = [:]

    private init() {}

    public func register(meshIndex: Int, mesh: MeshAsset) {
        let edges = Self.extractWireframeEdges(from: mesh)
        lock.lock()
        storage[meshIndex] = edges
        lock.unlock()
    }

    /// 注册单个拓扑来源（可带 index remap）。
    public func register(meshIndex: Int, topology: MeshWireframeTopology) {
        let edges = Self.extractWireframeEdges(from: topology)
        lock.lock()
        storage[meshIndex] = edges
        lock.unlock()
    }

    /// 注册多个子网格拓扑并合并去重边线。
    public func register(meshIndex: Int, submeshes: [MeshWireframeTopology]) {
        var merged: [MeshWireframeEdge] = []
        merged.reserveCapacity(submeshes.reduce(0) { $0 + $1.triangleIndices.count })
        var seen = Set<EdgeKey>()
        for submesh in submeshes {
            let edges = Self.extractWireframeEdges(from: submesh)
            for edge in edges {
                let key = EdgeKey(a: edge.a, b: edge.b)
                if seen.insert(key).inserted {
                    merged.append(edge)
                }
            }
        }
        lock.lock()
        storage[meshIndex] = merged
        lock.unlock()
    }

    public func edges(for meshIndex: Int) -> [MeshWireframeEdge]? {
        lock.lock()
        let value = storage[meshIndex]
        lock.unlock()
        return value
    }

    public func clearAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private static func extractWireframeEdges(from mesh: MeshAsset) -> [MeshWireframeEdge] {
        let stride = MeshAsset.vertexFloatCount
        guard stride >= 3 else { return [] }

        let vertexCount = mesh.vertices.count / stride
        if vertexCount <= 0 || mesh.indices.isEmpty {
            return []
        }

        var results: [MeshWireframeEdge] = []
        results.reserveCapacity(mesh.indices.count)
        var seen = Set<UInt64>()

        func position(_ index: UInt32) -> SIMD3<Float>? {
            let i = Int(index)
            guard i >= 0, i < vertexCount else { return nil }
            let base = i * stride
            return SIMD3<Float>(mesh.vertices[base], mesh.vertices[base + 1], mesh.vertices[base + 2])
        }

        func appendEdge(_ i0: UInt32, _ i1: UInt32) {
            if i0 == i1 { return }
            let lo = min(i0, i1)
            let hi = max(i0, i1)
            let key = (UInt64(lo) << 32) | UInt64(hi)
            if seen.contains(key) { return }
            guard let a = position(i0), let b = position(i1) else { return }
            seen.insert(key)
            results.append(MeshWireframeEdge(a: a, b: b))
        }

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i]
            let b = mesh.indices[i + 1]
            let c = mesh.indices[i + 2]
            appendEdge(a, b)
            appendEdge(b, c)
            appendEdge(c, a)
            i += 3
        }

        return results
    }

    private static func extractWireframeEdges(from topology: MeshWireframeTopology)
        -> [MeshWireframeEdge] {
        if topology.positions.isEmpty || topology.triangleIndices.isEmpty {
            return []
        }

        var results: [MeshWireframeEdge] = []
        results.reserveCapacity(topology.triangleIndices.count)
        var seen = Set<UInt64>()

        func resolve(_ index: UInt32) -> UInt32? {
            guard let remap = topology.indexRemap else { return index }
            let i = Int(index)
            guard i >= 0, i < remap.count else { return nil }
            return remap[i]
        }

        func position(_ index: UInt32) -> SIMD3<Float>? {
            let i = Int(index)
            guard i >= 0, i < topology.positions.count else { return nil }
            return topology.positions[i]
        }

        func appendEdge(_ rawI0: UInt32, _ rawI1: UInt32) {
            guard let i0 = resolve(rawI0), let i1 = resolve(rawI1), i0 != i1 else { return }
            let lo = min(i0, i1)
            let hi = max(i0, i1)
            let key = (UInt64(lo) << 32) | UInt64(hi)
            if seen.contains(key) { return }
            guard let a = position(i0), let b = position(i1) else { return }
            seen.insert(key)
            results.append(MeshWireframeEdge(a: a, b: b))
        }

        var i = 0
        while i + 2 < topology.triangleIndices.count {
            let a = topology.triangleIndices[i]
            let b = topology.triangleIndices[i + 1]
            let c = topology.triangleIndices[i + 2]
            appendEdge(a, b)
            appendEdge(b, c)
            appendEdge(c, a)
            i += 3
        }

        return results
    }

    private struct EdgeKey: Hashable {
        let ax: UInt32
        let ay: UInt32
        let az: UInt32
        let bx: UInt32
        let by: UInt32
        let bz: UInt32

        init(a: SIMD3<Float>, b: SIMD3<Float>) {
            let aq = Self.quantize(a)
            let bq = Self.quantize(b)
            if Self.isLexicographicallySorted(aq, bq) {
                (ax, ay, az) = aq
                (bx, by, bz) = bq
            } else {
                (ax, ay, az) = bq
                (bx, by, bz) = aq
            }
        }

        private static func quantize(_ v: SIMD3<Float>) -> (UInt32, UInt32, UInt32) {
            let s: Float = 10_000
            let qx = Int32((v.x * s).rounded())
            let qy = Int32((v.y * s).rounded())
            let qz = Int32((v.z * s).rounded())
            return (UInt32(bitPattern: qx), UInt32(bitPattern: qy), UInt32(bitPattern: qz))
        }

        private static func isLexicographicallySorted(_ lhs: (UInt32, UInt32, UInt32),
                                                      _ rhs: (UInt32, UInt32, UInt32)) -> Bool {
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 <= rhs.2
        }
    }
}
