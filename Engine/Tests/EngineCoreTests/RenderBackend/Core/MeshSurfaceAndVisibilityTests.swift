import AssetPipeline
import SceneRuntime
import SIMDCompat
import Testing
@testable import RenderBackend

@Suite("Mesh surface and visibility", .serialized)
struct MeshSurfaceAndVisibilityTests {
    @Test("triangle surfaces reject empty AABB corners and return nearest hits from either side")
    func preciseSurface() throws {
        let surface = MeshPickingSurface(positions: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 2, 0),
                                                     SIMD3(0, 0, -2), SIMD3(2, 0, -2), SIMD3(0, 2, -2)],
                                         indices: [0, 1, 2, 3, 4, 5])
        #expect(surface.hitDistance(origin: SIMD3(1.8, 1.8, 3), direction: SIMD3(0, 0, -1)) == nil)
        #expect(surface.hitDistance(origin: SIMD3(0.3, 0.3, 3), direction: SIMD3(0, 0, -1)) == 3)
        #expect(surface.hitDistance(origin: SIMD3(0.3, 0.3, -3), direction: SIMD3(0, 0, 1)) == 1)
        #expect(surface.hitDistance(origin: SIMD3(0.3, 0.3, 3), direction: SIMD3(0, 0, -0.5)) == 6)
        #expect(surface.hitDistance(origin: SIMD3(0.3, 0.3, 3), direction: SIMD3(0, 0, -1), maxDistance: 2) == nil)
        let invalid = MeshPickingSurface(positions: [.zero], indices: [0, 1, 2, 0, 0, 0])
        #expect(invalid.hitDistance(origin: SIMD3(0, 0, 1), direction: SIMD3(0, 0, -1)) == nil)
    }

    @Test("surface picking follows the current joint pose rather than the bind pose")
    func posedSurface() throws {
        var vertices: [Float] = []
        for position in [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)] {
            MeshAsset.appendVertex(to: &vertices, position: position)
        }
        let slot = 401_002
        MeshPickingRegistry.shared.register(meshIndex: slot,
            mesh: MeshAsset(name: "posed", vertices: vertices, indices: [0, 1, 2]))
        var joint = matrix_identity_float4x4; joint.columns.3.x = 3
        let posed = try #require(MeshPickingRegistry.shared.surface(for: slot, jointMatrices: [joint]))
        #expect(posed.hitDistance(origin: SIMD3(0.2, 0.2, 4), direction: SIMD3(0, 0, -1)) == nil)
        #expect(posed.hitDistance(origin: SIMD3(3.2, 0.2, 4), direction: SIMD3(0, 0, -1)) == 4)
        #expect(MeshMaterial(alphaCutoff: 2).alphaCutoff == 2)
    }

    @Test("BVH traverses both branches and rays parallel to a bound")
    func bvhTraversal() {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0..<40 {
            let x = Float(i) * 3
            let first = UInt32(positions.count)
            positions += [SIMD3(x, 0, 0), SIMD3(x + 1, 0, 0), SIMD3(x, 1, 0)]
            indices += [first, first + 1, first + 2]
        }
        let surface = MeshPickingSurface(positions: positions, indices: indices)
        for i in [0, 10, 20, 39] {
            #expect(surface.hitDistance(origin: SIMD3(Float(i) * 3 + 0.1, 0.1, 4), direction: SIMD3(0, 0, -1)) == 4)
        }
    }

    @Test("perspective and orthographic frusta cull outside bounds, retaining unknown and skinned geometry",
          arguments: [RenderCamera.Projection.perspective, .orthographic])
    func visibility(projection: RenderCamera.Projection) {
        let slot = 401_001
        MeshBoundsRegistry.shared.register(meshIndex: slot, min: SIMD3(repeating: -0.5), max: SIMD3(repeating: 0.5))
        let camera = RenderCamera(eye: SIMD3(0, 0, 5), target: .zero, projection: projection, orthographicHeight: 5)
        func instance(_ x: Float, _ z: Float, entity: EntityID? = nil, meshIndex: Int? = nil) -> RenderInstance {
            var matrix = matrix_identity_float4x4; matrix.columns.3 = SIMD4(x, 0, z, 1)
            return RenderInstance(meshIndex: meshIndex ?? slot, transform: matrix, entity: entity)
        }
        let skinned = EntityID(index: 99, generation: 0)
        let scene = RenderScene(camera: camera, instances: [instance(0, 0), instance(100, 0), instance(0, 10),
            instance(100, 0, entity: skinned), instance(100, 0, meshIndex: slot + 1)])
        let vp = RenderCameraMatrices.make(scene: scene, drawableSize: RenderDrawableSize(width: 128, height: 128)).viewProjection
        let plan = MeshVisibilityPlan.make(scene: scene, viewProjection: vp, settings: .init(),
            skinnedEntities: [skinned], meshBounds: { MeshBoundsRegistry.shared.bounds(for: $0) }, meshExists: { _ in true })
        #expect(plan.visibleIndices == [0, 3, 4])
        #expect(plan.culledCount == 2)
        let unculled = MeshVisibilityPlan.make(scene: scene, viewProjection: vp,
            settings: RenderSettings(enableFrustumCulling: false), skinnedEntities: [], meshBounds: { MeshBoundsRegistry.shared.bounds(for: $0) }, meshExists: { _ in true })
        #expect(unculled.visibleIndices.count == 5)
    }

    @Test("distance LOD selects available authored levels and respects the disabled switch")
    func distanceLOD() {
        let camera = RenderCamera(eye: SIMD3(0, 0, 10), target: .zero)
        let instance = RenderInstance(mesh: RenderMeshHandle(meshIndex: 100, levelsOfDetail: [
            RenderMeshLOD(meshIndex: 102, minimumDistance: 20), RenderMeshLOD(meshIndex: 101, minimumDistance: 5)]),
            transform: matrix_identity_float4x4)
        let scene = RenderScene(camera: camera, instances: [instance])
        let vp = RenderCameraMatrices.make(scene: scene, drawableSize: RenderDrawableSize(width: 128, height: 128)).viewProjection
        let plan = MeshVisibilityPlan.make(scene: scene, viewProjection: vp, settings: .init(),
            skinnedEntities: [], meshBounds: { MeshBoundsRegistry.shared.bounds(for: $0) }, meshExists: { $0 == 101 })
        #expect(plan.meshIndices[0] == 101 && plan.lodCount == 1)
        let missing = MeshVisibilityPlan.make(scene: scene, viewProjection: vp, settings: .init(),
            skinnedEntities: [], meshBounds: { MeshBoundsRegistry.shared.bounds(for: $0) }, meshExists: { _ in false })
        #expect(missing.meshIndices[0] == 100)
        let disabled = MeshVisibilityPlan.make(scene: scene, viewProjection: vp,
            settings: RenderSettings(enableDistanceLOD: false), skinnedEntities: [], meshBounds: { MeshBoundsRegistry.shared.bounds(for: $0) }, meshExists: { _ in true })
        #expect(disabled.meshIndices[0] == 100)
    }
}
