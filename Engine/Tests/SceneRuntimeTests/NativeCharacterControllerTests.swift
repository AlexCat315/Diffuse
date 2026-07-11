import SceneRuntime
import SIMDCompat
import Testing

@Suite("NativeCharacterController")
struct NativeCharacterControllerTests {
    private func makeScene(characterPosition: SIMD3<Float> = SIMD3<Float>(0, 2, 0)) -> (SceneRuntime, EntityID) {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1
            )
        )

        let floor = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, -0.5, 0)),
            for: floor
        )
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(10, 0.5, 10), center: .zero)),
            for: floor
        )

        let character = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: characterPosition), for: character)
        _ = runtime.setComponent(CharacterController(), for: character)
        return (runtime, character)
    }

    @Test("native character falls onto the ground and reports support")
    func landsAndReportsGroundState() {
        var (runtime, character) = makeScene()
        for frame in 0..<120 {
            runtime.submitCharacterCommand(CharacterCommand(), for: character)
            _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
        }

        let state = runtime.characterStateFrame.states[character]
        #expect(state?.isGrounded == true)
        // Character transforms use a stable foot-space origin, independent of stance.
        #expect(abs(state?.position.y ?? 1) < 0.08)
        #expect(runtime.worldTransform(for: character)?.translation == state?.position)
    }

    @Test("native character consumes desired velocity in the current frame")
    func movesUsingCurrentFrameCommand() {
        var (runtime, character) = makeScene(characterPosition: SIMD3<Float>(0, 1, 0))
        for frame in 0..<90 {
            runtime.submitCharacterCommand(CharacterCommand(), for: character)
            _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
        }
        let before = runtime.worldTransform(for: character)?.translation.x ?? 0
        runtime.submitCharacterCommand(
            CharacterCommand(desiredVelocity: SIMD3<Float>(3, 0, 0)),
            for: character
        )
        _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: 11)
        let after = runtime.worldTransform(for: character)?.translation.x ?? 0
        #expect(after > before + 0.04)
    }

    @Test("native character jumps and changes stance")
    func jumpsAndCrouches() {
        var (runtime, character) = makeScene(characterPosition: SIMD3<Float>(0, 1, 0))
        for frame in 0..<90 {
            runtime.submitCharacterCommand(CharacterCommand(), for: character)
            _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
        }
        let groundedY = runtime.worldTransform(for: character)?.translation.y ?? 0
        runtime.submitCharacterCommand(
            CharacterCommand(jumpRequested: true, jumpSpeed: 6, stance: .crouching),
            for: character
        )
        _ = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: 11)
        let state = runtime.characterStateFrame.states[character]
        #expect((state?.position.y ?? 0) > groundedY)
        #expect(state?.linearVelocity.y ?? 0 > 0)
        #expect(state?.stance == .crouching)
    }
}
