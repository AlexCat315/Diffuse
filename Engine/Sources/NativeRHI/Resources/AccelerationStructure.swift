/// Non-indexed opaque triangle geometry. Vertices contain three float32
/// coordinates at each stride. Future geometry kinds get their own types.
public struct TriangleGeometry: Sendable {
    public var vertices: Buffer
    public var vertexOffset = 0
    public var vertexStride = 12
    public var triangleCount: Int

    public init(vertices: Buffer, triangleCount: Int) {
        self.vertices = vertices
        self.triangleCount = triangleCount
    }
}

/// Three rows of an affine transform. Backends pack their native GPU layout.
public struct InstanceTransform: Sendable {
    public var x = SIMD4<Float>(1, 0, 0, 0)
    public var y = SIMD4<Float>(0, 1, 0, 0)
    public var z = SIMD4<Float>(0, 0, 1, 0)
    public init() {}
}

public struct AccelerationInstance: Sendable {
    public var structure: AccelerationStructure
    public var transform = InstanceTransform()
    public var mask: UInt32 = 0xff
    public init(structure: AccelerationStructure) { self.structure = structure }
}

public enum AccelerationStructureDescriptor: Sendable {
    case bottomLevel([TriangleGeometry])
    case topLevel([AccelerationInstance])
}

/// The build command retains its input dependencies in the recorded stream so
/// SubmissionPlanner can order build-input reads, BLAS/TLAS writes and queries.
public struct AccelerationStructureBuild: Sendable {
    public var structure: AccelerationStructure
    public var inputs: [ResourceRef]
}
