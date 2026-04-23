import Foundation
import simd

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
    public static func load(path: String) throws -> MeshAsset {
        try loadWithTopology(path: path).mesh
    }

    public static func loadWithTopology(path: String) throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GLTFImporterError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        return try parseWithTopology(data: data,
                                     baseURL: url.deletingLastPathComponent(),
                                     name: url.lastPathComponent)
    }

    static func parse(data: Data, baseURL: URL, name: String) throws -> MeshAsset {
        try parseWithTopology(data: data, baseURL: baseURL, name: name).mesh
    }

    static func parseWithTopology(data: Data, baseURL: URL, name: String)
        throws -> (mesh: MeshAsset, topologies: [MeshTopologySlice]) {
        let document: GLTFDocument
        do {
            document = try JSONDecoder().decode(GLTFDocument.self, from: data)
        } catch {
            throw GLTFImporterError.invalidJSON(String(describing: error))
        }

        let buffers = try document.buffers.map { try resolveBuffer($0, baseURL: baseURL) }
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
            let primitiveIndices = try primitive.indices.map(readIndexAccessor)
                ?? Array(0..<positions.count)

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

                vertices.append(contentsOf: [
                    worldPosition.x, worldPosition.y, worldPosition.z,
                    worldNormal.x, worldNormal.y, worldNormal.z,
                    1, 1, 1,
                ])
                indices.append(nextIndex)
                nextIndex += 1
            }
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
        var mesh = MeshAsset(name: name, vertices: vertices, indices: indices)
        MeshNormalTools.fillMissingNormals(vertices: &mesh.vertices, indices: mesh.indices)
        return (mesh, topologies)
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

private struct GLTFDocument: Decodable {
    let scene: Int?
    let scenes: [GLTFScene]?
    let nodes: [GLTFNode]?
    let meshes: [GLTFMesh]?
    let accessors: [GLTFAccessor]
    let bufferViews: [GLTFBufferView]?
    let buffers: [GLTFBuffer]
}

private struct GLTFScene: Decodable {
    let nodes: [Int]?
}

private struct GLTFNode: Decodable {
    let mesh: Int?
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
}

private struct GLTFAccessor: Decodable {
    let bufferView: Int?
    let byteOffset: Int?
    let componentType: Int
    let count: Int
    let type: String
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}