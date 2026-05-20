import EngineMath
@testable import RenderBackend
import SIMDCompat
import Testing

@Suite("MeshBoundsRegistry", .serialized)
struct MeshBoundsRegistryTests {
    @Test("stores typed bounds while preserving tuple lookup")
    func storesTypedBounds() {
        let registry = MeshBoundsRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let bounds = Bounds3D(
            min: SIMD3<Float>(-1, -2, -3),
            max: SIMD3<Float>(1, 2, 3)
        )
        registry.register(meshIndex: 3, bounds: bounds)

        #expect(registry.bounds3D(for: 3) == bounds)
        #expect(registry.bounds(for: 3)?.min == bounds.min)
        #expect(registry.bounds(for: 3)?.max == bounds.max)
    }
}
