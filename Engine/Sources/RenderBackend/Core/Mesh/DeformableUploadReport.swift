struct DeformableMeshUploadReport: Sendable, Equatable {
    var meshCount: Int = 0
    var vertexCount: Int = 0
    var triangleCount: Int = 0
    var uploadedBytes: UInt64 = 0
    var rejectedMeshCount: Int = 0
}
