import GuavaUICore
import NativeRHI

/// One bounded snapshot of validated geometry and its logical clip decisions.
/// Retaining Swift's value arrays makes any subsequent mutation detach storage;
/// identical live buffers therefore prove identical contents, without hashing or
/// trusting a mutable DrawList identity. Viewport and bindings are still resolved
/// on each recording.
struct NativeUIGeometry {
    private let vertices: [UIVertex]
    private let indices: [UInt32]
    private let batches: [DrawBatch]
    let reliesOnClip: [Bool]

    init(validating list: DrawList) throws {
        try Self.validate(list)
        vertices = list.vertices
        indices = list.indices
        batches = list.batches
        reliesOnClip = list.batches.map { Self.reliesOnScissorClip(list: list, batch: $0) }
    }

    func matches(_ list: DrawList) -> Bool {
        Self.sharesStorage(vertices, list.vertices)
            && Self.sharesStorage(indices, list.indices)
            && Self.sharesStorage(batches, list.batches)
    }

    private static func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.isEmpty { return true }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    private static func validate(_ list: DrawList) throws {
        let vertexCount = list.vertices.count, indexCount = list.indices.count
        // Keep complete validation even for unused geometry, but walk concrete
        // contiguous storage. Sequence.allSatisfy uses unspecialized iterator
        // witnesses and per-element allocation in an unoptimized Swift build.
        try list.vertices.withUnsafeBufferPointer { vertices in
            var index = 0
            while index < vertices.count {
                let vertex = vertices[index]
                guard vertex.posX.isFinite && vertex.posY.isFinite && vertex.u.isFinite && vertex.v.isFinite else {
                    throw RHIError.invalidArgument("invalid UI vertices or indices")
                }
                index += 1
            }
        }
        try list.indices.withUnsafeBufferPointer { indices in
            var index = 0
            while index < indices.count {
                guard Int(indices[index]) < vertexCount else {
                    throw RHIError.invalidArgument("invalid UI vertices or indices")
                }
                index += 1
            }
        }
        for batch in list.batches {
            let offset = Int(batch.indexOffset), count = Int(batch.indexCount)
            guard offset <= indexCount && count <= indexCount - offset && count % 3 == 0 else {
                throw RHIError.invalidArgument("UI batch index range exceeds the draw list")
            }
        }
    }
}

extension NativeUIGeometry {
    /// Detects whether a batch's scissor performs a real clip. Most batches carry
    /// a scissor equal to their own geometry bounds, which clips nothing; only
    /// those can safely share a draw with a neighbour.
    static func reliesOnScissorClip(list: DrawList, batch: DrawBatch) -> Bool {
        guard let rect = batch.scissor else { return false }
        let tolerance: Float = 0.01
        let minX = rect.minX - tolerance, minY = rect.minY - tolerance
        let maxX = rect.maxX + tolerance, maxY = rect.maxY + tolerance
        // Borrow the arrays once. Repeated cross-module getters and generic
        // collection iteration are costly for every index in debug builds.
        return list.vertices.withUnsafeBufferPointer { vertices in
            list.indices.withUnsafeBufferPointer { indices in
                var index = Int(batch.indexOffset)
                let end = index + Int(batch.indexCount)
                while index < end {
                    let vertex = vertices[Int(indices[index])]
                    if vertex.posX < minX || vertex.posY < minY
                        || vertex.posX > maxX || vertex.posY > maxY { return true }
                    index += 1
                }
                return false
            }
        }
    }
}

