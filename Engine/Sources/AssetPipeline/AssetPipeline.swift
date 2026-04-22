import Foundation
import simd

public struct AssetPipeline {
    public init() {}

    public func validatePath(_ path: String) -> Bool {
        !path.isEmpty
    }
}

// MARK: - Mesh Asset

/// Interleaved mesh: position (3 floats) + normal (3 floats) + color (3 floats),
/// stride = 36 bytes. Indices are 32-bit. Used as the canonical R1-stage input format.
public struct MeshAsset: Sendable {
    public static let vertexStride: Int = 36
    public static let positionOffset: Int = 0
    public static let normalOffset: Int = 12
    public static let colorOffset: Int = 24

    public var vertices: [Float]
    public var indices: [UInt32]
    public var name: String

    public init(name: String, vertices: [Float], indices: [UInt32]) {
        self.name = name
        self.vertices = vertices
        self.indices = indices
    }

    public var indexCount: UInt32 { UInt32(indices.count) }
    public var vertexBufferSize: Int { vertices.count * MemoryLayout<Float>.size }
    public var indexBufferSize: Int { indices.count * MemoryLayout<UInt32>.size }

    /// Local-space axis-aligned bounding box of all vertex positions.
    /// 空 mesh 退化为 (.zero, .zero)。
    public var localBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        let stride = MeshAsset.vertexStride / MemoryLayout<Float>.size
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var i = 0
        while i < vertices.count {
            let v = SIMD3<Float>(vertices[i], vertices[i + 1], vertices[i + 2])
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
            i += stride
        }
        if lo.x == .infinity { return (.zero, .zero) }
        return (lo, hi)
    }

    /// Recenter to origin and uniform-scale longest axis to `targetSize`.
    public mutating func normalizeToUnitBounds(targetSize: Float = 2.0) {
        let stride = MeshAsset.vertexStride / MemoryLayout<Float>.size
        var minX: Float = .infinity, minY: Float = .infinity, minZ: Float = .infinity
        var maxX: Float = -.infinity, maxY: Float = -.infinity, maxZ: Float = -.infinity
        var i = 0
        while i < vertices.count {
            let x = vertices[i], y = vertices[i + 1], z = vertices[i + 2]
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
            if z < minZ { minZ = z }; if z > maxZ { maxZ = z }
            i += stride
        }
        let cx = (minX + maxX) * 0.5
        let cy = (minY + maxY) * 0.5
        let cz = (minZ + maxZ) * 0.5
        let extent = max(maxX - minX, max(maxY - minY, maxZ - minZ))
        let scale = extent > 0 ? (targetSize / extent) : 1.0
        i = 0
        while i < vertices.count {
            vertices[i]     = (vertices[i]     - cx) * scale
            vertices[i + 1] = (vertices[i + 1] - cy) * scale
            vertices[i + 2] = (vertices[i + 2] - cz) * scale
            i += stride
        }
    }
}

// MARK: - Built-in Cube

public enum BuiltinMesh {
    /// Unit cube centered at origin, side length 1. 24 vertices, 36 indices, per-face color.
    public static func cube() -> MeshAsset {
        let faces: [(n: (Float, Float, Float),
                     c: (Float, Float, Float),
                     verts: [(Float, Float, Float)])] = [
            ((1, 0, 0),  (1.0, 0.2, 0.2),  [( 0.5, -0.5, -0.5), ( 0.5,  0.5, -0.5), ( 0.5,  0.5,  0.5), ( 0.5, -0.5,  0.5)]),
            ((-1, 0, 0), (0.2, 1.0, 0.2),  [(-0.5, -0.5,  0.5), (-0.5,  0.5,  0.5), (-0.5,  0.5, -0.5), (-0.5, -0.5, -0.5)]),
            ((0, 1, 0),  (0.2, 0.2, 1.0),  [(-0.5,  0.5,  0.5), ( 0.5,  0.5,  0.5), ( 0.5,  0.5, -0.5), (-0.5,  0.5, -0.5)]),
            ((0, -1, 0), (1.0, 1.0, 0.2),  [(-0.5, -0.5, -0.5), ( 0.5, -0.5, -0.5), ( 0.5, -0.5,  0.5), (-0.5, -0.5,  0.5)]),
            ((0, 0, 1),  (1.0, 0.2, 1.0),  [(-0.5, -0.5,  0.5), ( 0.5, -0.5,  0.5), ( 0.5,  0.5,  0.5), (-0.5,  0.5,  0.5)]),
            ((0, 0, -1), (0.2, 1.0, 1.0),  [( 0.5, -0.5, -0.5), (-0.5, -0.5, -0.5), (-0.5,  0.5, -0.5), ( 0.5,  0.5, -0.5)]),
        ]

        var vertices: [Float] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(faces.count * 4 * 9)
        indices.reserveCapacity(faces.count * 6)

        for (faceIdx, face) in faces.enumerated() {
            for v in face.verts {
                vertices.append(contentsOf: [
                    v.0, v.1, v.2,
                    face.n.0, face.n.1, face.n.2,
                    face.c.0, face.c.1, face.c.2,
                ])
            }
            let base = UInt32(faceIdx * 4)
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return MeshAsset(name: "builtin.cube", vertices: vertices, indices: indices)
    }
}

// MARK: - OBJ Loader (minimal)

public enum OBJLoaderError: Error {
    case fileNotFound(String)
    case parseFailed(String)
}

/// Minimal Wavefront OBJ loader. Supports v / vn / f only. Triangulates fan-style.
/// Missing normals zero out; colors default to white. R1 fixture loader.
public enum OBJLoader {
    public static func load(path: String) throws -> MeshAsset {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw OBJLoaderError.fileNotFound(path)
        }
        return try parse(text: text, name: (path as NSString).lastPathComponent)
    }

    public static func parse(text: String, name: String) throws -> MeshAsset {
        var positions: [(Float, Float, Float)] = []
        var normals: [(Float, Float, Float)] = []
        var vertices: [Float] = []
        var indices: [UInt32] = []
        var nextIndex: UInt32 = 0

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = parts.first else { continue }

            switch head {
            case "v":
                guard parts.count >= 4,
                      let x = Float(parts[1]),
                      let y = Float(parts[2]),
                      let z = Float(parts[3]) else {
                    throw OBJLoaderError.parseFailed("bad vertex: \(line)")
                }
                positions.append((x, y, z))

            case "vn":
                guard parts.count >= 4,
                      let x = Float(parts[1]),
                      let y = Float(parts[2]),
                      let z = Float(parts[3]) else {
                    throw OBJLoaderError.parseFailed("bad normal: \(line)")
                }
                normals.append((x, y, z))

            case "f":
                let face = Array(parts.dropFirst())
                guard face.count >= 3 else {
                    throw OBJLoaderError.parseFailed("bad face: \(line)")
                }
                var resolved: [(pos: (Float, Float, Float), nrm: (Float, Float, Float))] = []
                resolved.reserveCapacity(face.count)
                for token in face {
                    let segs = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                    guard let viStr = segs.first, let viRaw = Int(viStr) else {
                        throw OBJLoaderError.parseFailed("bad face index: \(token)")
                    }
                    let pi = viRaw > 0 ? viRaw - 1 : positions.count + viRaw
                    guard positions.indices.contains(pi) else {
                        throw OBJLoaderError.parseFailed("face position out of range: \(token)")
                    }
                    var n: (Float, Float, Float) = (0, 0, 0)
                    if segs.count >= 3, let niRaw = Int(segs[2]) {
                        let ni = niRaw > 0 ? niRaw - 1 : normals.count + niRaw
                        if normals.indices.contains(ni) { n = normals[ni] }
                    }
                    resolved.append((positions[pi], n))
                }
                for i in 1..<(resolved.count - 1) {
                    for vert in [resolved[0], resolved[i], resolved[i + 1]] {
                        vertices.append(contentsOf: [
                            vert.pos.0, vert.pos.1, vert.pos.2,
                            vert.nrm.0, vert.nrm.1, vert.nrm.2,
                            1.0, 1.0, 1.0,
                        ])
                        indices.append(nextIndex)
                        nextIndex += 1
                    }
                }

            default:
                continue
            }
        }

        if vertices.isEmpty {
            throw OBJLoaderError.parseFailed("no triangles parsed")
        }
        fillMissingNormals(vertices: &vertices, indices: indices)
        return MeshAsset(name: name, vertices: vertices, indices: indices)
    }

    /// For any triangle whose three vertices all have a zero normal, generate a face normal
    /// and write it to those slots. Triangles whose normals were already supplied by the OBJ
    /// (via `vn` references) are left untouched.
    private static func fillMissingNormals(vertices: inout [Float], indices: [UInt32]) {
        let stride = MeshAsset.vertexStride / MemoryLayout<Float>.size // 9
        var i = 0
        while i + 2 < indices.count {
            let i0 = Int(indices[i]) * stride
            let i1 = Int(indices[i + 1]) * stride
            let i2 = Int(indices[i + 2]) * stride

            // Check if any of the three vertices already has a non-zero normal.
            func hasNormal(_ base: Int) -> Bool {
                vertices[base + 3] != 0 || vertices[base + 4] != 0 || vertices[base + 5] != 0
            }
            if hasNormal(i0) || hasNormal(i1) || hasNormal(i2) {
                i += 3
                continue
            }

            let p0x = vertices[i0], p0y = vertices[i0 + 1], p0z = vertices[i0 + 2]
            let p1x = vertices[i1], p1y = vertices[i1 + 1], p1z = vertices[i1 + 2]
            let p2x = vertices[i2], p2y = vertices[i2 + 1], p2z = vertices[i2 + 2]

            let ax = p1x - p0x, ay = p1y - p0y, az = p1z - p0z
            let bx = p2x - p0x, by = p2y - p0y, bz = p2z - p0z
            var nx = ay * bz - az * by
            var ny = az * bx - ax * bz
            var nz = ax * by - ay * bx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            if len > 0 {
                nx /= len; ny /= len; nz /= len
            }

            for slot in [i0, i1, i2] {
                vertices[slot + 3] = nx
                vertices[slot + 4] = ny
                vertices[slot + 5] = nz
            }
            i += 3
        }
    }
}
