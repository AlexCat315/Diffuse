import AssetPipeline
import Foundation
import RHIWGPU
import SceneRuntime
import SIMDCompat
import Testing
@testable import RenderBackend

private let deformableGPUSmokeEnabled =
    ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] == "1"

@Suite("DeformableMeshUpload", .serialized)
struct DeformableMeshUploadTests {
    @Test("packs deformable positions, normals, UVs, and indices into the mesh vertex contract")
    func buildsInterleavedVertexStream() throws {
        let entity = EntityID(index: 4, generation: 2)
        let mesh = Self.makeQuad(entity: entity, revision: 7)
        let stream = try #require(DeformableMeshVertexStream(mesh))

        #expect(stream.vertices.count == 4 * MeshAsset.vertexFloatCount)
        #expect(stream.indices == [0, 1, 2, 0, 2, 3])
        #expect(stream.vertexBufferSize == UInt64(4 * MeshAsset.vertexStride))
        #expect(stream.indexBufferSize == UInt64(6 * MemoryLayout<UInt32>.size))
        #expect(stream.vertices[MeshAsset.positionFloatOffset] == -1)
        #expect(stream.vertices[MeshAsset.normalFloatOffset + 2] == 1)
        #expect(stream.vertices[MeshAsset.uvFloatOffset] == 0)
        #expect(stream.vertices[
            2 * MeshAsset.vertexFloatCount + MeshAsset.uvFloatOffset
        ] == 1)

        var invalid = mesh
        invalid.triangleIndices[5] = 99
        #expect(!invalid.isValid)
        #expect(DeformableMeshVertexStream(invalid) == nil)
    }

    @Test(
        "uploads deformable GPU buffers once per content revision",
        .enabled(
            if: deformableGPUSmokeEnabled,
            "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU smoke test"
        )
    )
    func uploadsOncePerRevision() throws {
        let backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: true))
        try backend.initialize()
        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }
        let activeRenderer = try #require(renderer)
        activeRenderer.initialize()

        let entity = EntityID(index: 1, generation: 0)
        var mesh = Self.makeQuad(entity: entity, revision: 1)
        activeRenderer.render(packet: Self.packet(entity: entity, mesh: mesh, frame: 0))
        var stats = activeRenderer.currentFrameStats()
        #expect(stats.deformableMeshCount == 1)
        #expect(stats.deformableVertexCount == 4)
        #expect(stats.deformableTriangleCount == 2)
        #expect(stats.deformableRejectedMeshCount == 0)
        #expect(stats.deformableUploadedBytes == 408)

        activeRenderer.render(packet: Self.packet(entity: entity, mesh: mesh, frame: 1))
        stats = activeRenderer.currentFrameStats()
        #expect(stats.deformableUploadedBytes == 0)

        mesh.revision = 2
        mesh.positions[0].y = -0.5
        mesh.normals = RenderDeformableMesh.smoothNormals(
            positions: mesh.positions,
            triangleIndices: mesh.triangleIndices
        )
        activeRenderer.render(packet: Self.packet(entity: entity, mesh: mesh, frame: 2))
        stats = activeRenderer.currentFrameStats()
        #expect(stats.deformableUploadedBytes == UInt64(4 * MeshAsset.vertexStride))
    }

    private static func makeQuad(
        entity: EntityID,
        revision: UInt64
    ) -> RenderDeformableMesh {
        RenderDeformableMesh(
            entity: entity,
            revision: revision,
            positions: [
                SIMD3<Float>(-1, -1, 0),
                SIMD3<Float>(1, -1, 0),
                SIMD3<Float>(1, 1, 0),
                SIMD3<Float>(-1, 1, 0),
            ],
            triangleIndices: [0, 1, 2, 0, 2, 3],
            textureCoordinates: [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(1, 1),
                SIMD2<Float>(0, 1),
            ]
        )
    }

    private static func packet(
        entity: EntityID,
        mesh: RenderDeformableMesh,
        frame: Int
    ) -> RenderPacket {
        RenderPacket(
            frameIndex: frame,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: 64, height: 64),
            scene: RenderScene(
                camera: RenderCamera(eye: SIMD3<Float>(0, 0, 4)),
                instances: [
                    RenderInstance(
                        meshIndex: 0,
                        transform: matrix_identity_float4x4,
                        entity: entity
                    )
                ],
                deformableMeshes: [mesh]
            ),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: UInt64(frame)),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: Double(frame) / 60.0
        )
    }
}
