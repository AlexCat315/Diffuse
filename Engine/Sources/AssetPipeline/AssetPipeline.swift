import Foundation
import simd

public struct AssetPipeline {
    public init() {}

    public func validatePath(_ path: String) -> Bool {
        !path.isEmpty
    }
}

// MARK: - Mesh Asset

public struct MeshTexture: Sendable, Equatable {
    public var name: String?
    public var sourceURI: String?
    public var mimeType: String?
    public var samplerIndex: Int?
    public var data: Data?

    public init(name: String? = nil,
                sourceURI: String? = nil,
                mimeType: String? = nil,
                samplerIndex: Int? = nil,
                data: Data?) {
        self.name = name
        self.sourceURI = sourceURI
        self.mimeType = mimeType
        self.samplerIndex = samplerIndex
        self.data = data
    }

    public init(name: String? = nil,
                sourceURI: String? = nil,
                mimeType: String? = nil,
                samplerIndex: Int? = nil) {
        self.init(name: name,
                  sourceURI: sourceURI,
                  mimeType: mimeType,
                  samplerIndex: samplerIndex,
                  data: nil)
    }
}

public struct MeshMaterial: Sendable, Equatable {
    public var name: String?
    public var baseColorFactor: SIMD4<Float>
    public var baseColorTextureIndex: Int?
    public var normalTextureIndex: Int?
    public var metallicFactor: Float
    public var roughnessFactor: Float

    public init(name: String? = nil,
                baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                baseColorTextureIndex: Int? = nil,
                normalTextureIndex: Int? = nil,
                metallicFactor: Float = 1,
                roughnessFactor: Float = 1) {
        self.name = name
        self.baseColorFactor = baseColorFactor
        self.baseColorTextureIndex = baseColorTextureIndex
        self.normalTextureIndex = normalTextureIndex
        self.metallicFactor = metallicFactor
        self.roughnessFactor = roughnessFactor
    }

    public static let fallback = MeshMaterial()
}

/// One node from the GLTF node hierarchy.
///
/// Stores the node's local TRS so `AnimationRuntime` can override the transform
/// of individual joints at runtime without re-importing the asset.
public struct MeshNode: Sendable, Equatable {
    public var name: String?
    public var parentIndex: Int?         // nil = root
    public var localTranslation: SIMD3<Float>
    public var localRotation: SIMD4<Float>   // quaternion xyzw
    public var localScale: SIMD3<Float>

    public init(name: String? = nil,
                parentIndex: Int? = nil,
                localTranslation: SIMD3<Float> = .zero,
                localRotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
                localScale: SIMD3<Float> = .one) {
        self.name = name
        self.parentIndex = parentIndex
        self.localTranslation = localTranslation
        self.localRotation = localRotation
        self.localScale = localScale
    }

    /// Compose the node's local TRS into a 4×4 matrix.
    public var localMatrix: simd_float4x4 {
        let t = simd_float4x4(rows: [
            SIMD4<Float>(1, 0, 0, localTranslation.x),
            SIMD4<Float>(0, 1, 0, localTranslation.y),
            SIMD4<Float>(0, 0, 1, localTranslation.z),
            SIMD4<Float>(0, 0, 0, 1),
        ])
        let q = localRotation
        let x2 = q.x*q.x, y2 = q.y*q.y, z2 = q.z*q.z
        let xy = q.x*q.y, xz = q.x*q.z, yz = q.y*q.z
        let wx = q.w*q.x, wy = q.w*q.y, wz = q.w*q.z
        let r = simd_float4x4(rows: [
            SIMD4<Float>(1-2*(y2+z2), 2*(xy-wz),   2*(xz+wy),   0),
            SIMD4<Float>(2*(xy+wz),   1-2*(x2+z2), 2*(yz-wx),   0),
            SIMD4<Float>(2*(xz-wy),   2*(yz+wx),   1-2*(x2+y2), 0),
            SIMD4<Float>(0,           0,           0,            1),
        ])
        let s = simd_float4x4(rows: [
            SIMD4<Float>(localScale.x, 0, 0, 0),
            SIMD4<Float>(0, localScale.y, 0, 0),
            SIMD4<Float>(0, 0, localScale.z, 0),
            SIMD4<Float>(0, 0, 0, 1),
        ])
        return t * r * s
    }
}

public struct MeshSkin: Sendable, Equatable {
    public var name: String?
    public var jointNodeIndices: [Int]
    public var inverseBindMatrices: [simd_float4x4]

    public init(name: String? = nil,
                jointNodeIndices: [Int],
                inverseBindMatrices: [simd_float4x4] = []) {
        self.name = name
        self.jointNodeIndices = jointNodeIndices
        self.inverseBindMatrices = inverseBindMatrices
    }
}

public enum MeshAnimationInterpolation: String, Sendable, Equatable {
    case linear
    case step
    case cubicSpline
}

public enum MeshAnimationPath: String, Sendable, Equatable {
    case translation
    case rotation
    case scale
    case weights
}

public struct MeshAnimationSampler: Sendable, Equatable {
    public var inputTimes: [Float]
    public var outputValues: [SIMD4<Float>]
    public var interpolation: MeshAnimationInterpolation

    public init(inputTimes: [Float],
                outputValues: [SIMD4<Float>],
                interpolation: MeshAnimationInterpolation = .linear) {
        self.inputTimes = inputTimes
        self.outputValues = outputValues
        self.interpolation = interpolation
    }
}

public struct MeshAnimationChannel: Sendable, Equatable {
    public var samplerIndex: Int
    public var targetNodeIndex: Int?
    public var path: MeshAnimationPath

    public init(samplerIndex: Int, targetNodeIndex: Int?, path: MeshAnimationPath) {
        self.samplerIndex = samplerIndex
        self.targetNodeIndex = targetNodeIndex
        self.path = path
    }
}

public struct MeshAnimation: Sendable, Equatable {
    public var name: String?
    public var samplers: [MeshAnimationSampler]
    public var channels: [MeshAnimationChannel]

    public init(name: String? = nil,
                samplers: [MeshAnimationSampler],
                channels: [MeshAnimationChannel]) {
        self.name = name
        self.samplers = samplers
        self.channels = channels
    }
}

/// Interleaved mesh vertex stream used by runtime render backends.
///
/// Layout, in floats:
/// position3 + normal3 + color3 + uv2 + tangent4 + materialIndex1 + joints4 + weights4.
public struct MeshAsset: Sendable {
    public static let vertexFloatCount: Int = 24
    public static let vertexStride: Int = vertexFloatCount * MemoryLayout<Float>.size
    public static let positionOffset: Int = 0
    public static let normalOffset: Int = 12
    public static let colorOffset: Int = 24
    public static let uvOffset: Int = 36
    public static let tangentOffset: Int = 44
    public static let materialIndexOffset: Int = 60
    public static let jointsOffset: Int = 64
    public static let weightsOffset: Int = 80

    public static let positionFloatOffset: Int = 0
    public static let normalFloatOffset: Int = 3
    public static let colorFloatOffset: Int = 6
    public static let uvFloatOffset: Int = 9
    public static let tangentFloatOffset: Int = 11
    public static let materialIndexFloatOffset: Int = 15
    public static let jointsFloatOffset: Int = 16
    public static let weightsFloatOffset: Int = 20

    public var vertices: [Float]
    public var indices: [UInt32]
    public var name: String
    public var materials: [MeshMaterial]
    public var textures: [MeshTexture]
    public var nodes: [MeshNode]
    public var skins: [MeshSkin]
    public var animations: [MeshAnimation]

    public init(name: String,
                vertices: [Float],
                indices: [UInt32],
                materials: [MeshMaterial] = [MeshMaterial.fallback],
                textures: [MeshTexture] = [],
                nodes: [MeshNode] = [],
                skins: [MeshSkin] = [],
                animations: [MeshAnimation] = []) {
        self.name = name
        self.vertices = vertices
        self.indices = indices
        self.materials = materials.isEmpty ? [MeshMaterial.fallback] : materials
        self.textures = textures
        self.nodes = nodes
        self.skins = skins
        self.animations = animations
    }

    public var indexCount: UInt32 { UInt32(indices.count) }
    public var vertexCount: Int { vertices.count / MeshAsset.vertexFloatCount }
    public var triangleCount: Int { indices.count / 3 }
    public var vertexBufferSize: Int { vertices.count * MemoryLayout<Float>.size }
    public var indexBufferSize: Int { indices.count * MemoryLayout<UInt32>.size }

    public func position(at vertexIndex: Int) -> SIMD3<Float>? {
        guard vertexIndex >= 0, vertexIndex < vertexCount else { return nil }
        let offset = vertexIndex * MeshAsset.vertexFloatCount + MeshAsset.positionFloatOffset
        return SIMD3<Float>(vertices[offset], vertices[offset + 1], vertices[offset + 2])
    }

    public mutating func setPosition(_ position: SIMD3<Float>, at vertexIndex: Int) {
        guard vertexIndex >= 0, vertexIndex < vertexCount else { return }
        let offset = vertexIndex * MeshAsset.vertexFloatCount + MeshAsset.positionFloatOffset
        vertices[offset] = position.x
        vertices[offset + 1] = position.y
        vertices[offset + 2] = position.z
    }

    public mutating func transformPositions(by matrix: simd_float4x4) {
        for vertexIndex in 0..<vertexCount {
            guard let position = position(at: vertexIndex) else { continue }
            let transformed = matrix * SIMD4<Float>(position.x, position.y, position.z, 1)
            setPosition(SIMD3<Float>(transformed.x, transformed.y, transformed.z), at: vertexIndex)
        }
    }

    public static func appendVertex(
        to vertices: inout [Float],
        position: SIMD3<Float>,
        normal: SIMD3<Float> = .zero,
        color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        uv: SIMD2<Float> = .zero,
        tangent: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1),
        materialIndex: Float = 0,
        joints: SIMD4<Float> = .zero,
        weights: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    ) {
        vertices.append(contentsOf: [
            position.x, position.y, position.z,
            normal.x, normal.y, normal.z,
            color.x, color.y, color.z,
            uv.x, uv.y,
            tangent.x, tangent.y, tangent.z, tangent.w,
            materialIndex,
            joints.x, joints.y, joints.z, joints.w,
            weights.x, weights.y, weights.z, weights.w,
        ])
    }

    /// Local-space axis-aligned bounding box of all vertex positions.
    /// 空 mesh 退化为 (.zero, .zero)。
    public var localBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        let stride = MeshAsset.vertexFloatCount
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
        let stride = MeshAsset.vertexFloatCount
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

/// 子网格拓扑切片：可用于 wireframe、调试渲染或后续子网格重建。
/// `indexRemap` 允许把局部 primitive 索引映射到共享顶点池。
public struct MeshTopologySlice: Sendable {
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
        vertices.reserveCapacity(faces.count * 4 * MeshAsset.vertexFloatCount)
        indices.reserveCapacity(faces.count * 6)

        for (faceIdx, face) in faces.enumerated() {
            for v in face.verts {
                MeshAsset.appendVertex(
                    to: &vertices,
                    position: SIMD3<Float>(v.0, v.1, v.2),
                    normal: SIMD3<Float>(face.n.0, face.n.1, face.n.2),
                    color: SIMD3<Float>(face.c.0, face.c.1, face.c.2)
                )
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
                        MeshAsset.appendVertex(
                            to: &vertices,
                            position: SIMD3<Float>(vert.pos.0, vert.pos.1, vert.pos.2),
                            normal: SIMD3<Float>(vert.nrm.0, vert.nrm.1, vert.nrm.2)
                        )
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
        let stride = MeshAsset.vertexFloatCount
        var i = 0
        while i + 2 < indices.count {
            let i0 = Int(indices[i]) * stride
            let i1 = Int(indices[i + 1]) * stride
            let i2 = Int(indices[i + 2]) * stride

            // Check if any of the three vertices already has a non-zero normal.
            func hasNormal(_ base: Int) -> Bool {
                vertices[base + MeshAsset.normalFloatOffset] != 0
                    || vertices[base + MeshAsset.normalFloatOffset + 1] != 0
                    || vertices[base + MeshAsset.normalFloatOffset + 2] != 0
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
                vertices[slot + MeshAsset.normalFloatOffset] = nx
                vertices[slot + MeshAsset.normalFloatOffset + 1] = ny
                vertices[slot + MeshAsset.normalFloatOffset + 2] = nz
            }
            i += 3
        }
    }
}

enum MeshNormalTools {
    static func fillMissingNormals(vertices: inout [Float], indices: [UInt32]) {
        let stride = MeshAsset.vertexFloatCount
        var i = 0
        while i + 2 < indices.count {
            let i0 = Int(indices[i]) * stride
            let i1 = Int(indices[i + 1]) * stride
            let i2 = Int(indices[i + 2]) * stride

            func hasNormal(_ base: Int) -> Bool {
                vertices[base + MeshAsset.normalFloatOffset] != 0
                    || vertices[base + MeshAsset.normalFloatOffset + 1] != 0
                    || vertices[base + MeshAsset.normalFloatOffset + 2] != 0
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
                vertices[slot + MeshAsset.normalFloatOffset] = nx
                vertices[slot + MeshAsset.normalFloatOffset + 1] = ny
                vertices[slot + MeshAsset.normalFloatOffset + 2] = nz
            }
            i += 3
        }
    }
}
