import Foundation
import SIMDCompat

/// Per-primitive topology using shared vertex pool with optional index remap.
public struct PrimitiveMeshTopology: Sendable {
    public var triangleIndices: [UInt32]
    public var indexRemap: [UInt32]?

    public init(triangleIndices: [UInt32], indexRemap: [UInt32]? = nil) {
        self.triangleIndices = triangleIndices
        self.indexRemap = indexRemap
    }
}

public enum GLTFImporterError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidJSON(String)
    case unsupportedBuffer(String)
    case unsupportedPrimitiveMode(Int)
    case missingSceneGraph(Int?)
    case missingMesh(Int)
    case missingAccessor(Int)
    case invalidAccessor(String)
    case outOfBounds(String)

    public var description: String {
        switch self {
        case let .fileNotFound(path):
            return "gltf file not found: \(path)"
        case let .invalidJSON(reason):
            return "invalid gltf json: \(reason)"
        case let .unsupportedBuffer(reason):
            return "unsupported gltf buffer: \(reason)"
        case let .unsupportedPrimitiveMode(mode):
            return "unsupported gltf primitive mode: \(mode)"
        case let .missingSceneGraph(index):
            if let index {
                return "missing scene graph object at index \(index)"
            }
            return "missing scene graph"
        case let .missingMesh(index):
            return "missing mesh at index \(index)"
        case let .missingAccessor(index):
            return "missing accessor at index \(index)"
        case let .invalidAccessor(reason):
            return "invalid accessor: \(reason)"
        case let .outOfBounds(reason):
            return "buffer access out of bounds: \(reason)"
        }
    }
}

public enum GLTFImporter {
    private static let glbMagic: UInt32 = 0x46546C67
    private static let chunkTypeJSON: UInt32 = 0x4E4F534A
    private static let chunkTypeBIN: UInt32 = 0x004E4942

    public static func load(path: String) throws -> MeshAsset {
        try loadWithTopology(path: path).mesh
    }

    public static func loadWithTopology(path: String) throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GLTFImporterError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        let baseURL = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        if isGLB(data) {
            let (jsonData, binData) = try extractGLBChunks(data)
            return try parseWithTopology(jsonData: jsonData, binBuffer: binData, baseURL: baseURL, name: name)
        }
        return try parseWithTopology(data: data, baseURL: baseURL, name: name)
    }

    /// Load GLTF with shared vertex pool across all primitives, useful for reducing position redundancy.
    /// Returns a shared position array and per-primitive topology slices with index remap if needed.
    public static func loadWithSharedVertexPool(path: String) throws -> (positions: [SIMD3<Float>], primitives: [PrimitiveMeshTopology]) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GLTFImporterError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        let baseURL = url.deletingLastPathComponent()
        if isGLB(data) {
            let (jsonData, binData) = try extractGLBChunks(data)
            return try parseWithSharedVertexPool(jsonData: jsonData, binBuffer: binData, baseURL: baseURL)
        }
        return try parseWithSharedVertexPool(data: data, baseURL: baseURL)
    }

    static func parse(data: Data, baseURL: URL, name: String) throws -> MeshAsset {
        try parseWithTopology(data: data, baseURL: baseURL, name: name).mesh
    }

    static func parseWithTopology(data: Data, baseURL: URL, name: String)
        throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        let document = try decodeGLTFDocument(data)
        let buffers = try document.buffers.map { try resolveBuffer($0, baseURL: baseURL) }
        return try buildMeshWithTopology(document: document, buffers: buffers, name: name)
    }

    static func parseWithTopology(jsonData: Data, binBuffer: Data?, baseURL: URL, name: String)
        throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        let document = try decodeGLTFDocument(jsonData)
        let buffers = try resolveGLBBuffers(document: document, binBuffer: binBuffer, baseURL: baseURL)
        return try buildMeshWithTopology(document: document, buffers: buffers, name: name)
    }

    static func parseWithSharedVertexPool(data: Data, baseURL: URL)
        throws -> (positions: [SIMD3<Float>], primitives: [PrimitiveMeshTopology]) {
        let document = try decodeGLTFDocument(data)
        let buffers = try document.buffers.map { try resolveBuffer($0, baseURL: baseURL) }
        return try buildSharedVertexPool(document: document, buffers: buffers)
    }

    static func parseWithSharedVertexPool(jsonData: Data, binBuffer: Data?, baseURL: URL)
        throws -> (positions: [SIMD3<Float>], primitives: [PrimitiveMeshTopology]) {
        let document = try decodeGLTFDocument(jsonData)
        let buffers = try resolveGLBBuffers(document: document, binBuffer: binBuffer, baseURL: baseURL)
        return try buildSharedVertexPool(document: document, buffers: buffers)
    }

    private static func decodeGLTFDocument(_ data: Data) throws -> GLTFDocument {
        do {
            return try JSONDecoder().decode(GLTFDocument.self, from: data)
        } catch {
            throw GLTFImporterError.invalidJSON(String(describing: error))
        }
    }

    private static func buildMeshWithTopology(document: GLTFDocument, buffers: [Data], name: String)
        throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        let rootNodes = try rootNodeIndices(in: document)
        guard !rootNodes.isEmpty else {
            throw GLTFImporterError.missingSceneGraph(nil)
        }
        var builder = MeshBuilder(document: document, buffers: buffers)
        for nodeIndex in rootNodes {
            try builder.consumeNode(index: nodeIndex, parentTransform: matrix_identity_float4x4)
        }
        return try builder.makeMeshWithTopology(name: name)
    }

    private static func buildSharedVertexPool(document: GLTFDocument, buffers: [Data])
        throws -> (positions: [SIMD3<Float>], primitives: [PrimitiveMeshTopology]) {
        let rootNodes = try rootNodeIndices(in: document)
        guard !rootNodes.isEmpty else {
            throw GLTFImporterError.missingSceneGraph(nil)
        }
        var sharedBuilder = SharedVertexPoolBuilder(document: document, buffers: buffers)
        for nodeIndex in rootNodes {
            try sharedBuilder.consumeNode(index: nodeIndex, parentTransform: matrix_identity_float4x4)
        }
        return try sharedBuilder.makePrimitivesWithSharedPool()
    }

    private static func resolveGLBBuffers(document: GLTFDocument, binBuffer: Data?, baseURL: URL) throws -> [Data] {
        try document.buffers.enumerated().map { (i, buffer) in
            if buffer.uri == nil, i == 0, let bin = binBuffer {
                return bin
            }
            return try resolveBuffer(buffer, baseURL: baseURL)
        }
    }

    private static func isGLB(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) } == glbMagic
    }

    private static func extractGLBChunks(_ data: Data) throws -> (json: Data, bin: Data?) {
        guard data.count >= 12 else {
            throw GLTFImporterError.unsupportedBuffer("GLB file too short")
        }
        var offset = 12
        var jsonData: Data?
        var binData: Data?
        while offset + 8 <= data.count {
            let chunkLength = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
            let chunkType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
            offset += 8
            guard offset + chunkLength <= data.count else {
                throw GLTFImporterError.unsupportedBuffer("GLB chunk extends beyond file bounds")
            }
            switch chunkType {
            case chunkTypeJSON:
                jsonData = data.subdata(in: offset..<(offset + chunkLength))
            case chunkTypeBIN:
                binData = data.subdata(in: offset..<(offset + chunkLength))
            default:
                break
            }
            offset += chunkLength
        }
        guard let json = jsonData else {
            throw GLTFImporterError.unsupportedBuffer("GLB file missing JSON chunk")
        }
        return (json, binData)
    }

    private static func rootNodeIndices(in document: GLTFDocument) throws -> [Int] {
        if let sceneIndex = document.scene,
           let scenes = document.scenes,
           scenes.indices.contains(sceneIndex) {
            return scenes[sceneIndex].nodes ?? []
        }
        if let firstNodes = document.scenes?.first?.nodes, !firstNodes.isEmpty {
            return firstNodes
        }

        let nodes = document.nodes ?? []
        guard !nodes.isEmpty else { return [] }
        var children = Set<Int>()
        for node in nodes {
            for child in node.children ?? [] {
                children.insert(child)
            }
        }
        let roots = nodes.indices.filter { !children.contains($0) }
        return roots.isEmpty ? Array(nodes.indices) : roots
    }

    private static func resolveBuffer(_ buffer: GLTFBuffer, baseURL: URL) throws -> Data {
        guard let uri = buffer.uri else {
            throw GLTFImporterError.unsupportedBuffer("GLB container buffers are not supported yet")
        }

        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else {
                throw GLTFImporterError.unsupportedBuffer("malformed data URI")
            }
            let metadata = uri[..<comma]
            let payload = String(uri[uri.index(after: comma)...])
            if metadata.contains(";base64") {
                guard let decoded = Data(base64Encoded: payload) else {
                    throw GLTFImporterError.unsupportedBuffer("invalid base64 data URI")
                }
                return decoded
            }
            guard let text = payload.removingPercentEncoding else {
                throw GLTFImporterError.unsupportedBuffer("invalid percent-encoded data URI")
            }
            return Data(text.utf8)
        }

        let url = baseURL.appendingPathComponent(uri)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GLTFImporterError.fileNotFound(url.path)
        }
        return try Data(contentsOf: url)
    }
}

private struct MeshBuilder {
    let document: GLTFDocument
    let buffers: [Data]

    var vertices: [Float] = []
    var indices: [UInt32] = []
    var nextIndex: UInt32 = 0
    var topologies: [MeshTopologySlice] = []
    var submeshes: [MeshSubmesh] = []

    mutating func consumeNode(index: Int, parentTransform: simd_float4x4) throws {
        guard let node = document.nodes?[safe: index] else {
            throw GLTFImporterError.missingSceneGraph(index)
        }
        let worldTransform = parentTransform * node.localTransform
        if let meshIndex = node.mesh {
            try consumeMesh(index: meshIndex, transform: worldTransform)
        }
        for child in node.children ?? [] {
            try consumeNode(index: child, parentTransform: worldTransform)
        }
    }

    mutating func consumeMesh(index: Int, transform: simd_float4x4) throws {
        guard let mesh = document.meshes?[safe: index] else {
            throw GLTFImporterError.missingMesh(index)
        }

        for primitive in mesh.primitives {
            let mode = primitive.mode ?? 4
            guard mode == 4 else {
                throw GLTFImporterError.unsupportedPrimitiveMode(mode)
            }
            guard let positionAccessor = primitive.attributes["POSITION"] else {
                throw GLTFImporterError.invalidAccessor("primitive missing POSITION attribute")
            }

            let positions = try readFloat3Accessor(index: positionAccessor)
            let normals = try primitive.attributes["NORMAL"].map(readFloat3Accessor)
            let uvs = try primitive.attributes["TEXCOORD_0"].map(readFloat2Accessor)
            let tangents = try primitive.attributes["TANGENT"].map(readFloat4Accessor)
            let joints = try primitive.attributes["JOINTS_0"].map(readJoint4Accessor)
            let weights = try primitive.attributes["WEIGHTS_0"].map(readWeight4Accessor)
            let primMaterialIndex = primitive.material ?? 0
            let materialIndex = Float(primMaterialIndex)
            let primitiveIndices = try primitive.indices.map(readIndexAccessor)
                ?? Array(0..<positions.count)

            let submeshIndexStart = UInt32(indices.count)

            let topologyPositions = positions.map { local in
                let p = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                return SIMD3<Float>(p.x, p.y, p.z)
            }
            let topologyIndices = primitiveIndices.map(UInt32.init)
            topologies.append(
                MeshTopologySlice(positions: topologyPositions,
                                  triangleIndices: topologyIndices,
                                  indexRemap: nil)
            )

            let basis = simd_float3x3(columns: (
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            ))
            let normalMatrix = simd_transpose(simd_inverse(basis))

            for rawIndex in primitiveIndices {
                guard positions.indices.contains(rawIndex) else {
                    throw GLTFImporterError.outOfBounds("position index \(rawIndex) out of range")
                }
                let localPosition = positions[rawIndex]
                let worldPosition4 = transform * SIMD4<Float>(localPosition.x,
                                                              localPosition.y,
                                                              localPosition.z,
                                                              1)
                let worldPosition = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)

                let worldNormal: SIMD3<Float>
                if let normals, normals.indices.contains(rawIndex) {
                    let transformed = normalMatrix * normals[rawIndex]
                    worldNormal = simd_length_squared(transformed) > 0
                        ? simd_normalize(transformed)
                        : SIMD3<Float>(0, 0, 0)
                } else {
                    worldNormal = SIMD3<Float>(0, 0, 0)
                }

                let uv = uvs.flatMap { $0.indices.contains(rawIndex) ? $0[rawIndex] : nil } ?? .zero
                let tangent = tangents.flatMap { $0.indices.contains(rawIndex) ? $0[rawIndex] : nil }
                    ?? SIMD4<Float>(1, 0, 0, 1)
                let joint = joints.flatMap { $0.indices.contains(rawIndex) ? $0[rawIndex] : nil } ?? .zero
                let weight = weights.flatMap { $0.indices.contains(rawIndex) ? $0[rawIndex] : nil }
                    ?? SIMD4<Float>(1, 0, 0, 0)

                MeshAsset.appendVertex(
                    to: &vertices,
                    position: worldPosition,
                    normal: worldNormal,
                    uv: uv,
                    tangent: tangent,
                    materialIndex: materialIndex,
                    joints: joint,
                    weights: weight
                )
                indices.append(nextIndex)
                nextIndex += 1
            }
            let submeshIndexCount = UInt32(indices.count) - submeshIndexStart
            submeshes.append(MeshSubmesh(indexStart: submeshIndexStart,
                                         indexCount: submeshIndexCount,
                                         materialIndex: primMaterialIndex))
        }
    }

    func readFloat2Accessor(index: Int) throws -> [SIMD2<Float>] {
        let accessor = try accessor(at: index)
        guard accessor.type == "VEC2" else {
            throw GLTFImporterError.invalidAccessor("expected VEC2 accessor at index \(index)")
        }
        guard accessor.componentType == 5126 else {
            throw GLTFImporterError.invalidAccessor("expected FLOAT component type for accessor \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let stride = view.byteStride ?? 8
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            return SIMD2<Float>(
                try readValue(Float.self, from: data, offset: offset),
                try readValue(Float.self, from: data, offset: offset + 4)
            )
        }
    }

    func readFloatScalarAccessor(index: Int) throws -> [Float] {
        let accessor = try accessor(at: index)
        guard accessor.type == "SCALAR" else {
            throw GLTFImporterError.invalidAccessor("expected SCALAR accessor at index \(index)")
        }
        guard accessor.componentType == 5126 else {
            throw GLTFImporterError.invalidAccessor("expected FLOAT component type for accessor \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let stride = view.byteStride ?? 4
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            try readValue(Float.self, from: data, offset: baseOffset + element * stride)
        }
    }

    func readFloat3Accessor(index: Int) throws -> [SIMD3<Float>] {
        let accessor = try accessor(at: index)
        guard accessor.type == "VEC3" else {
            throw GLTFImporterError.invalidAccessor("expected VEC3 accessor at index \(index)")
        }
        guard accessor.componentType == 5126 else {
            throw GLTFImporterError.invalidAccessor("expected FLOAT component type for accessor \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let stride = view.byteStride ?? 12
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            return SIMD3<Float>(
                try readValue(Float.self, from: data, offset: offset),
                try readValue(Float.self, from: data, offset: offset + 4),
                try readValue(Float.self, from: data, offset: offset + 8)
            )
        }
    }

    func readFloat4Accessor(index: Int) throws -> [SIMD4<Float>] {
        let accessor = try accessor(at: index)
        guard accessor.type == "VEC4" else {
            throw GLTFImporterError.invalidAccessor("expected VEC4 accessor at index \(index)")
        }
        guard accessor.componentType == 5126 else {
            throw GLTFImporterError.invalidAccessor("expected FLOAT component type for accessor \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let stride = view.byteStride ?? 16
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            return SIMD4<Float>(
                try readValue(Float.self, from: data, offset: offset),
                try readValue(Float.self, from: data, offset: offset + 4),
                try readValue(Float.self, from: data, offset: offset + 8),
                try readValue(Float.self, from: data, offset: offset + 12)
            )
        }
    }

    func readAnimationOutputAccessor(index: Int) throws -> [SIMD4<Float>] {
        let accessor = try accessor(at: index)
        switch accessor.type {
        case "SCALAR":
            return try readFloatScalarAccessor(index: index).map { SIMD4<Float>($0, 0, 0, 0) }
        case "VEC3":
            return try readFloat3Accessor(index: index).map { SIMD4<Float>($0.x, $0.y, $0.z, 0) }
        case "VEC4":
            return try readFloat4Accessor(index: index)
        default:
            throw GLTFImporterError.invalidAccessor("unsupported animation output accessor type \(accessor.type)")
        }
    }

    func readFloat4x4Accessor(index: Int) throws -> [simd_float4x4] {
        let accessor = try accessor(at: index)
        guard accessor.type == "MAT4" else {
            throw GLTFImporterError.invalidAccessor("expected MAT4 accessor at index \(index)")
        }
        guard accessor.componentType == 5126 else {
            throw GLTFImporterError.invalidAccessor("expected FLOAT component type for accessor \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let stride = view.byteStride ?? 64
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            return simd_float4x4(columns: (
                SIMD4<Float>(
                    try readValue(Float.self, from: data, offset: offset),
                    try readValue(Float.self, from: data, offset: offset + 4),
                    try readValue(Float.self, from: data, offset: offset + 8),
                    try readValue(Float.self, from: data, offset: offset + 12)
                ),
                SIMD4<Float>(
                    try readValue(Float.self, from: data, offset: offset + 16),
                    try readValue(Float.self, from: data, offset: offset + 20),
                    try readValue(Float.self, from: data, offset: offset + 24),
                    try readValue(Float.self, from: data, offset: offset + 28)
                ),
                SIMD4<Float>(
                    try readValue(Float.self, from: data, offset: offset + 32),
                    try readValue(Float.self, from: data, offset: offset + 36),
                    try readValue(Float.self, from: data, offset: offset + 40),
                    try readValue(Float.self, from: data, offset: offset + 44)
                ),
                SIMD4<Float>(
                    try readValue(Float.self, from: data, offset: offset + 48),
                    try readValue(Float.self, from: data, offset: offset + 52),
                    try readValue(Float.self, from: data, offset: offset + 56),
                    try readValue(Float.self, from: data, offset: offset + 60)
                )
            ))
        }
    }

    func readJoint4Accessor(index: Int) throws -> [SIMD4<Float>] {
        let accessor = try accessor(at: index)
        guard accessor.type == "VEC4" else {
            throw GLTFImporterError.invalidAccessor("expected VEC4 accessor at index \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let componentSize = try byteWidth(of: accessor.componentType)
        let stride = view.byteStride ?? componentSize * 4
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            switch accessor.componentType {
            case 5121:
                return SIMD4<Float>(
                    Float(try readValue(UInt8.self, from: data, offset: offset)),
                    Float(try readValue(UInt8.self, from: data, offset: offset + 1)),
                    Float(try readValue(UInt8.self, from: data, offset: offset + 2)),
                    Float(try readValue(UInt8.self, from: data, offset: offset + 3))
                )
            case 5123:
                return SIMD4<Float>(
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset))),
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset + 2))),
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset + 4))),
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset + 6)))
                )
            default:
                throw GLTFImporterError.invalidAccessor("unsupported joint component type \(accessor.componentType)")
            }
        }
    }

    func readWeight4Accessor(index: Int) throws -> [SIMD4<Float>] {
        let accessor = try accessor(at: index)
        guard accessor.type == "VEC4" else {
            throw GLTFImporterError.invalidAccessor("expected VEC4 accessor at index \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let componentSize = try byteWidth(of: accessor.componentType)
        let stride = view.byteStride ?? componentSize * 4
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            switch accessor.componentType {
            case 5126:
                return SIMD4<Float>(
                    try readValue(Float.self, from: data, offset: offset),
                    try readValue(Float.self, from: data, offset: offset + 4),
                    try readValue(Float.self, from: data, offset: offset + 8),
                    try readValue(Float.self, from: data, offset: offset + 12)
                )
            case 5121:
                let divisor: Float = accessor.normalized == true ? 255 : 1
                return SIMD4<Float>(
                    Float(try readValue(UInt8.self, from: data, offset: offset)) / divisor,
                    Float(try readValue(UInt8.self, from: data, offset: offset + 1)) / divisor,
                    Float(try readValue(UInt8.self, from: data, offset: offset + 2)) / divisor,
                    Float(try readValue(UInt8.self, from: data, offset: offset + 3)) / divisor
                )
            case 5123:
                let divisor: Float = accessor.normalized == true ? 65_535 : 1
                return SIMD4<Float>(
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset))) / divisor,
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset + 2))) / divisor,
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset + 4))) / divisor,
                    Float(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset + 6))) / divisor
                )
            default:
                throw GLTFImporterError.invalidAccessor("unsupported weight component type \(accessor.componentType)")
            }
        }
    }

    func readIndexAccessor(index: Int) throws -> [Int] {
        let accessor = try accessor(at: index)
        guard accessor.type == "SCALAR" else {
            throw GLTFImporterError.invalidAccessor("expected SCALAR accessor at index \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let componentSize = try byteWidth(of: accessor.componentType)
        let stride = view.byteStride ?? componentSize
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            switch accessor.componentType {
            case 5121:
                return Int(try readValue(UInt8.self, from: data, offset: offset))
            case 5123:
                return Int(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset)))
            case 5125:
                return Int(UInt32(littleEndian: try readValue(UInt32.self, from: data, offset: offset)))
            default:
                throw GLTFImporterError.invalidAccessor("unsupported index component type \(accessor.componentType)")
            }
        }
    }

    func makeMesh(name: String) throws -> MeshAsset {
        try makeMeshWithTopology(name: name).mesh
    }

    func makeMeshWithTopology(name: String) throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        guard !vertices.isEmpty else {
            throw GLTFImporterError.invalidAccessor("gltf produced no triangles")
        }
        var mesh = MeshAsset(
            name: name,
            vertices: vertices,
            indices: indices,
            materials: document.meshMaterials(),
            textures: document.meshTextures(buffers: buffers),
            nodes: meshNodes(),
            skins: try meshSkins(),
            animations: try meshAnimations(),
            submeshes: submeshes
        )
        MeshNormalTools.fillMissingNormals(vertices: &mesh.vertices, indices: mesh.indices)
        return (mesh, topologies)
    }

    func meshNodes() -> [MeshNode] {
        guard let gltfNodes = document.nodes, !gltfNodes.isEmpty else { return [] }
        // Build parent lookup: child 鈫?parent index
        var parentOf = [Int: Int]()
        for (i, node) in gltfNodes.enumerated() {
            for child in node.children ?? [] {
                parentOf[child] = i
            }
        }
        return gltfNodes.enumerated().map { (i, node) in
            let t: SIMD3<Float>
            let r: SIMD4<Float>
            let s: SIMD3<Float>
            if let m = node.matrix, m.count == 16 {
                // Decompose column-major matrix
                let col0 = SIMD3<Float>(m[0], m[1], m[2])
                let col1 = SIMD3<Float>(m[4], m[5], m[6])
                let col2 = SIMD3<Float>(m[8], m[9], m[10])
                t = SIMD3<Float>(m[12], m[13], m[14])
                s = SIMD3<Float>(simd_length(col0), simd_length(col1), simd_length(col2))
                let rx = col0 / max(s.x, 1e-6)
                let ry = col1 / max(s.y, 1e-6)
                let rz = col2 / max(s.z, 1e-6)
                let q = simd_quatf(simd_float3x3(columns: (rx, ry, rz)))
                r = SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real)
            } else {
                if let tr = node.translation, tr.count == 3 {
                    t = SIMD3<Float>(tr[0], tr[1], tr[2])
                } else { t = .zero }
                if let ro = node.rotation, ro.count == 4 {
                    r = SIMD4<Float>(ro[0], ro[1], ro[2], ro[3])
                } else { r = SIMD4<Float>(0, 0, 0, 1) }
                if let sc = node.scale, sc.count == 3 {
                    s = SIMD3<Float>(sc[0], sc[1], sc[2])
                } else { s = .one }
            }
            return MeshNode(
                name: node.name,
                parentIndex: parentOf[i],
                localTranslation: t,
                localRotation: r,
                localScale: s
            )
        }
    }

    func meshSkins() throws -> [MeshSkin] {
        guard let skins = document.skins, !skins.isEmpty else { return [] }
        return try skins.map { skin in
            let inverseBindMatrices: [simd_float4x4]
            if let accessorIndex = skin.inverseBindMatrices {
                inverseBindMatrices = try readFloat4x4Accessor(index: accessorIndex)
            } else {
                inverseBindMatrices = Array(repeating: matrix_identity_float4x4,
                                            count: skin.joints.count)
            }
            return MeshSkin(name: skin.name,
                            jointNodeIndices: skin.joints,
                            inverseBindMatrices: inverseBindMatrices)
        }
    }

    func meshAnimations() throws -> [MeshAnimation] {
        guard let animations = document.animations, !animations.isEmpty else { return [] }
        return try animations.map { animation in
            let samplers = try animation.samplers.map { sampler in
                MeshAnimationSampler(
                    inputTimes: try readFloatScalarAccessor(index: sampler.input),
                    outputValues: try readAnimationOutputAccessor(index: sampler.output),
                    interpolation: MeshAnimationInterpolation(gltfName: sampler.interpolation)
                )
            }
            let channels = try animation.channels.map { channel in
                guard let path = MeshAnimationPath(rawValue: channel.target.path) else {
                    throw GLTFImporterError.invalidAccessor("unsupported animation target path \(channel.target.path)")
                }
                return MeshAnimationChannel(
                    samplerIndex: channel.sampler,
                    targetNodeIndex: channel.target.node,
                    path: path
                )
            }
            return MeshAnimation(name: animation.name,
                                 samplers: samplers,
                                 channels: channels)
        }
    }

    private func accessor(at index: Int) throws -> GLTFAccessor {
        guard let accessor = document.accessors[safe: index] else {
            throw GLTFImporterError.missingAccessor(index)
        }
        return accessor
    }

    private func bufferView(for accessor: GLTFAccessor, accessorIndex: Int) throws -> GLTFBufferView {
        guard let viewIndex = accessor.bufferView,
              let view = document.bufferViews?[safe: viewIndex] else {
            throw GLTFImporterError.invalidAccessor("accessor \(accessorIndex) has no bufferView")
        }
        guard buffers.indices.contains(view.buffer) else {
            throw GLTFImporterError.outOfBounds("buffer view references missing buffer \(view.buffer)")
        }
        return view
    }

    private func byteWidth(of componentType: Int) throws -> Int {
        switch componentType {
        case 5121: return 1
        case 5123: return 2
        case 5125, 5126: return 4
        default:
            throw GLTFImporterError.invalidAccessor("unsupported component type \(componentType)")
        }
    }

    private func readValue<T>(_ type: T.Type, from data: Data, offset: Int) throws -> T {
        let width = MemoryLayout<T>.size
        guard offset >= 0, offset + width <= data.count else {
            throw GLTFImporterError.outOfBounds("offset \(offset) width \(width) exceeds buffer size \(data.count)")
        }
        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
    }
}

private struct SharedVertexPoolBuilder {
    let document: GLTFDocument
    let buffers: [Data]

    var sharedPositions: [SIMD3<Float>] = []
    var primitives: [PrimitiveMeshTopology] = []
    var positionToSharedIndex: [String: UInt32] = [:]

    mutating func consumeNode(index: Int, parentTransform: simd_float4x4) throws {
        guard let node = document.nodes?[safe: index] else {
            throw GLTFImporterError.missingSceneGraph(index)
        }
        let worldTransform = parentTransform * node.localTransform
        if let meshIndex = node.mesh {
            try consumeMesh(index: meshIndex, transform: worldTransform)
        }
        for child in node.children ?? [] {
            try consumeNode(index: child, parentTransform: worldTransform)
        }
    }

    mutating func consumeMesh(index: Int, transform: simd_float4x4) throws {
        guard let mesh = document.meshes?[safe: index] else {
            throw GLTFImporterError.missingMesh(index)
        }

        for primitive in mesh.primitives {
            let mode = primitive.mode ?? 4
            guard mode == 4 else {
                throw GLTFImporterError.unsupportedPrimitiveMode(mode)
            }
            guard let positionAccessor = primitive.attributes["POSITION"] else {
                throw GLTFImporterError.invalidAccessor("primitive missing POSITION attribute")
            }

            let positions = try readFloat3Accessor(index: positionAccessor)
            let primitiveIndices = try primitive.indices.map(readIndexAccessor)
                ?? Array(0..<positions.count)

            var remappedIndices: [UInt32] = []
            var indexRemap: [UInt32]? = nil
            var remapNeeded = false

            for rawIndex in primitiveIndices {
                guard positions.indices.contains(rawIndex) else {
                    throw GLTFImporterError.outOfBounds("position index \(rawIndex) out of range")
                }

                let localPosition = positions[rawIndex]
                let worldPosition4 = transform * SIMD4<Float>(localPosition.x, localPosition.y, localPosition.z, 1)
                let worldPosition = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)

                let posKey = "\(worldPosition.x),\(worldPosition.y),\(worldPosition.z)"
                if let existingIndex = positionToSharedIndex[posKey] {
                    remappedIndices.append(existingIndex)
                } else {
                    let newIndex = UInt32(sharedPositions.count)
                    sharedPositions.append(worldPosition)
                    positionToSharedIndex[posKey] = newIndex
                    remappedIndices.append(newIndex)
                }

                if UInt32(rawIndex) != remappedIndices.last! {
                    remapNeeded = true
                }
            }

            if remapNeeded {
                indexRemap = (0..<primitiveIndices.count).map { i in UInt32(primitiveIndices[i]) }
            }

            primitives.append(
                PrimitiveMeshTopology(triangleIndices: remappedIndices, indexRemap: indexRemap)
            )
        }
    }

    func makePrimitivesWithSharedPool() throws -> (positions: [SIMD3<Float>], primitives: [PrimitiveMeshTopology]) {
        guard !sharedPositions.isEmpty else {
            throw GLTFImporterError.invalidAccessor("gltf produced no vertices in shared pool")
        }
        return (sharedPositions, primitives)
    }

    func readFloat3Accessor(index: Int) throws -> [SIMD3<Float>] {
        let accessor = try accessor(at: index)
        guard accessor.type == "VEC3" else {
            throw GLTFImporterError.invalidAccessor("expected VEC3 accessor at index \(index)")
        }
        guard accessor.componentType == 5126 else {
            throw GLTFImporterError.invalidAccessor("expected FLOAT component type for accessor \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let stride = view.byteStride ?? 12
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            return SIMD3<Float>(
                try readValue(Float.self, from: data, offset: offset),
                try readValue(Float.self, from: data, offset: offset + 4),
                try readValue(Float.self, from: data, offset: offset + 8)
            )
        }
    }

    func readIndexAccessor(index: Int) throws -> [Int] {
        let accessor = try accessor(at: index)
        guard accessor.type == "SCALAR" else {
            throw GLTFImporterError.invalidAccessor("expected SCALAR accessor at index \(index)")
        }
        let view = try bufferView(for: accessor, accessorIndex: index)
        let data = buffers[view.buffer]
        let componentSize = try byteWidth(of: accessor.componentType)
        let stride = view.byteStride ?? componentSize
        let baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        return try (0..<accessor.count).map { element in
            let offset = baseOffset + element * stride
            switch accessor.componentType {
            case 5121:
                return Int(try readValue(UInt8.self, from: data, offset: offset))
            case 5123:
                return Int(UInt16(littleEndian: try readValue(UInt16.self, from: data, offset: offset)))
            case 5125:
                return Int(UInt32(littleEndian: try readValue(UInt32.self, from: data, offset: offset)))
            default:
                throw GLTFImporterError.invalidAccessor("unsupported index component type \(accessor.componentType)")
            }
        }
    }

    private func accessor(at index: Int) throws -> GLTFAccessor {
        guard let accessor = document.accessors[safe: index] else {
            throw GLTFImporterError.missingAccessor(index)
        }
        return accessor
    }

    private func bufferView(for accessor: GLTFAccessor, accessorIndex: Int) throws -> GLTFBufferView {
        guard let viewIndex = accessor.bufferView,
              let view = document.bufferViews?[safe: viewIndex] else {
            throw GLTFImporterError.invalidAccessor("accessor \(accessorIndex) has no bufferView")
        }
        guard buffers.indices.contains(view.buffer) else {
            throw GLTFImporterError.invalidAccessor("accessor \(accessorIndex) references buffer \(view.buffer) which does not exist")
        }
        return view
    }

    private func byteWidth(of componentType: Int) throws -> Int {
        switch componentType {
        case 5121: return 1
        case 5123: return 2
        case 5125, 5126: return 4
        default:
            throw GLTFImporterError.invalidAccessor("unsupported component type \(componentType)")
        }
    }

    private func readValue<T>(_ type: T.Type, from data: Data, offset: Int) throws -> T {
        let width = MemoryLayout<T>.size
        guard offset >= 0, offset + width <= data.count else {
            throw GLTFImporterError.outOfBounds("offset \(offset) width \(width) exceeds buffer size \(data.count)")
        }
        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
    }
}

private struct GLTFDocument: Decodable {
    let scene: Int?
    let scenes: [GLTFScene]?
    let nodes: [GLTFNode]?
    let meshes: [GLTFMesh]?
    let materials: [GLTFMaterial]?
    let textures: [GLTFTexture]?
    let images: [GLTFImage]?
    let samplers: [GLTFSampler]?
    let skins: [GLTFSkin]?
    let animations: [GLTFAnimation]?
    let accessors: [GLTFAccessor]
    let bufferViews: [GLTFBufferView]?
    let buffers: [GLTFBuffer]
}

private struct GLTFScene: Decodable {
    let nodes: [Int]?
}

private struct GLTFNode: Decodable {
    let name: String?
    let mesh: Int?
    let skin: Int?
    let children: [Int]?
    let matrix: [Float]?
    let translation: [Float]?
    let rotation: [Float]?
    let scale: [Float]?

    var localTransform: simd_float4x4 {
        if let matrix, matrix.count == 16 {
            return simd_float4x4(columns: (
                SIMD4<Float>(matrix[0], matrix[1], matrix[2], matrix[3]),
                SIMD4<Float>(matrix[4], matrix[5], matrix[6], matrix[7]),
                SIMD4<Float>(matrix[8], matrix[9], matrix[10], matrix[11]),
                SIMD4<Float>(matrix[12], matrix[13], matrix[14], matrix[15])
            ))
        }

        let t = translationVector(translation)
        let s = scaleVector(scale)
        let r = rotationQuaternion(rotation)

        let translationMatrix = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        ))
        let rotationMatrix = simd_float4x4(r)
        let scaleMatrix = simd_float4x4(columns: (
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        return translationMatrix * rotationMatrix * scaleMatrix
    }

    private func translationVector(_ source: [Float]?) -> SIMD3<Float> {
        guard let source, source.count == 3 else { return .zero }
        return SIMD3<Float>(source[0], source[1], source[2])
    }

    private func scaleVector(_ source: [Float]?) -> SIMD3<Float> {
        guard let source, source.count == 3 else { return SIMD3<Float>(1, 1, 1) }
        return SIMD3<Float>(source[0], source[1], source[2])
    }

    private func rotationQuaternion(_ source: [Float]?) -> simd_quatf {
        guard let source, source.count == 4 else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        return simd_quatf(ix: source[0], iy: source[1], iz: source[2], r: source[3])
    }
}

private struct GLTFMesh: Decodable {
    let primitives: [GLTFPrimitive]
}

private struct GLTFPrimitive: Decodable {
    let attributes: [String: Int]
    let indices: Int?
    let mode: Int?
    let material: Int?
}

private struct GLTFMaterial: Decodable {
    let name: String?
    let pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    let normalTexture: GLTFTextureInfo?
}

private struct GLTFPBRMetallicRoughness: Decodable {
    let baseColorFactor: [Float]?
    let baseColorTexture: GLTFTextureInfo?
    let metallicFactor: Float?
    let roughnessFactor: Float?
}

private struct GLTFTextureInfo: Decodable {
    let index: Int
}

private struct GLTFTexture: Decodable {
    let name: String?
    let sampler: Int?
    let source: Int?
}

private struct GLTFImage: Decodable {
    let name: String?
    let uri: String?
    let bufferView: Int?
    let mimeType: String?
}

private struct GLTFSampler: Decodable {
    let name: String?
    let magFilter: Int?
    let minFilter: Int?
    let wrapS: Int?
    let wrapT: Int?
}

private struct GLTFSkin: Decodable {
    let name: String?
    let inverseBindMatrices: Int?
    let skeleton: Int?
    let joints: [Int]
}

private struct GLTFAnimation: Decodable {
    let name: String?
    let samplers: [GLTFAnimationSampler]
    let channels: [GLTFAnimationChannel]
}

private struct GLTFAnimationSampler: Decodable {
    let input: Int
    let output: Int
    let interpolation: String?
}

private struct GLTFAnimationChannel: Decodable {
    let sampler: Int
    let target: GLTFAnimationTarget
}

private struct GLTFAnimationTarget: Decodable {
    let node: Int?
    let path: String
}

private struct GLTFAccessor: Decodable {
    let bufferView: Int?
    let byteOffset: Int?
    let componentType: Int
    let count: Int
    let type: String
    let normalized: Bool?
}

private struct GLTFBufferView: Decodable {
    let buffer: Int
    let byteOffset: Int?
    let byteLength: Int
    let byteStride: Int?
}

private struct GLTFBuffer: Decodable {
    let uri: String?
    let byteLength: Int
}

private extension GLTFDocument {
    func meshMaterials() -> [MeshMaterial] {
        guard let materials, !materials.isEmpty else {
            return [MeshMaterial.fallback]
        }
        return materials.map { material in
            let pbr = material.pbrMetallicRoughness
            return MeshMaterial(
                name: material.name,
                baseColorFactor: Self.vec4(pbr?.baseColorFactor, fallback: SIMD4<Float>(1, 1, 1, 1)),
                baseColorTextureIndex: pbr?.baseColorTexture?.index,
                normalTextureIndex: material.normalTexture?.index,
                metallicFactor: pbr?.metallicFactor ?? 1,
                roughnessFactor: pbr?.roughnessFactor ?? 1
            )
        }
    }

    func meshTextures(buffers: [Data]) -> [MeshTexture] {
        guard let textures, !textures.isEmpty else { return [] }
        return textures.map { texture in
            let image = texture.source.flatMap { images?[safe: $0] }
            let data = image?.bufferView.flatMap { imageData(bufferViewIndex: $0, buffers: buffers) }
            return MeshTexture(
                name: texture.name ?? image?.name,
                sourceURI: image?.uri,
                mimeType: image?.mimeType,
                samplerIndex: texture.sampler,
                data: data
            )
        }
    }

    private func imageData(bufferViewIndex: Int, buffers: [Data]) -> Data? {
        guard let view = bufferViews?[safe: bufferViewIndex],
              let buffer = buffers[safe: view.buffer]
        else { return nil }
        let start = view.byteOffset ?? 0
        let end = start + view.byteLength
        guard start >= 0, end <= buffer.count else { return nil }
        return buffer.subdata(in: start..<end)
    }

    private static func vec4(_ values: [Float]?, fallback: SIMD4<Float>) -> SIMD4<Float> {
        guard let values, values.count >= 4 else { return fallback }
        return SIMD4<Float>(values[0], values[1], values[2], values[3])
    }
}

private extension MeshAnimationInterpolation {
    init(gltfName: String?) {
        switch gltfName {
        case "STEP":
            self = .step
        case "CUBICSPLINE":
            self = .cubicSpline
        default:
            self = .linear
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
