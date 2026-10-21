@testable import SceneRuntime
import SIMDCompat
import Testing

@Suite("Script transform batching")
struct ScriptTransformBatchTests {
    @Test("Local writes batch until a world-space read, including generic component reads")
    func deferredPropagation() throws {
        var world = RuntimeWorld()
        let parent = world.createEntity()
        let child = world.createEntity()
        _ = world.setParent(parent, for: child)
        world.propagateTransforms()
        var commands = RuntimeCommandBuffer()
        try withUnsafeMutablePointer(to: &world) { worldPointer in
            try withUnsafeMutablePointer(to: &commands) { commandPointer in
                let context = RuntimeScriptPhaseContext(
                    world: worldPointer, commands: commandPointer,
                    deltaTimeSeconds: 1.0 / 60, physicsQueryScene: PhysicsQueryScene(backend: NullPhysicsBackend()))
                for x in 1...32 {
                    #expect(context.setLocalTransform(LocalTransform(translation: SIMD3(Float(x), 0, 0)), for: parent))
                    #expect(worldPointer.pointee.hierarchyNeedsPropagation())
                }
                #expect(context.translate(SIMD3(0, 2, 0), for: child))
                #expect(context.localTransform(for: child)?.translation == SIMD3(0, 2, 0))
                #expect(worldPointer.pointee.hierarchyNeedsPropagation())
                #expect(context.worldTransform(for: child)?.translation == SIMD3(32, 2, 0))
                #expect(!worldPointer.pointee.hierarchyNeedsPropagation())
                #expect(context.translate(SIMD3(1, 0, 0), for: parent))
                let derived = try #require(context.component(WorldTransform.self, for: child))
                #expect(derived.translation == SIMD3(33, 2, 0))
                #expect(!worldPointer.pointee.hierarchyNeedsPropagation())
            }
        }
    }
}
