import SceneRuntime
import SIMDCompat
import Testing

@Suite("Ragdoll")
struct RagdollTests {
    @Test("animation, simulation, blending and partial-body modes share one mapping")
    func runtimeModes() throws {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            gravity: .zero,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false
        ))
        let root = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: root)
        let body = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: body)
        _ = runtime.setComponent(RigidBody(
            motionType: .dynamic,
            mass: 1,
            gravityScale: 0,
            allowSleep: false
        ), for: body)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.2, center: .zero)), for: body)
        _ = runtime.setComponent(Ragdoll(
            mode: .animated,
            bones: [RagdollBoneMapping(boneName: "hips", paletteIndex: 0, bodyEntity: body)]
        ), for: root)

        runtime.setResource(JointPaletteMap(palettes: [
            root: JointPalette(matrices: [translationMatrix(SIMD3<Float>(0, 2, 0))]),
        ]))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.component(RigidBody.self, for: body)?.motionType == .kinematic)
        #expect(abs((runtime.worldTransform(for: body)?.translation.y ?? 0) - 2) < 0.001)
        #expect(runtime.ragdollStateFrame.states[root]?.bones.first?.isSimulated == false)

        _ = runtime.setRagdollMode(.simulated, for: root)
        _ = runtime.updateComponent(RigidBody.self, for: body) {
            $0.linearVelocity = SIMD3<Float>(1, 0, 0)
        }
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.component(RigidBody.self, for: body)?.motionType == .dynamic)
        #expect(runtime.ragdollStateFrame.states[root]?.bones.first?.isSimulated == true)
        let simulatedX = runtime.worldTransform(for: body)?.translation.x ?? 0
        #expect(simulatedX > 0)
        #expect(abs((runtime.resource(JointPaletteMap.self)?.palettes[root]?.matrices[0].columns.3.x ?? 0) - simulatedX) < 0.001)

        _ = runtime.setRagdollMode(.blended, for: root, blendWeight: 0.5)
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 2, 0)), for: body)
        _ = runtime.updateComponent(RigidBody.self, for: body) { $0.linearVelocity = .zero }
        runtime.setResource(JointPaletteMap(palettes: [root: JointPalette(matrices: [matrix_identity_float4x4])]))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        let blendedX = runtime.resource(JointPaletteMap.self)?.palettes[root]?.matrices[0].columns.3.x ?? 0
        #expect(abs(blendedX - 1) < 0.02)

        let disabledBone = runtime.setRagdollBoneSimulation(false, paletteIndex: 0, for: root)
        #expect(disabledBone)
        _ = runtime.setRagdollMode(.simulated, for: root)
        runtime.setResource(JointPaletteMap(palettes: [
            root: JointPalette(matrices: [translationMatrix(SIMD3<Float>(0, 4, 0))]),
        ]))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.component(RigidBody.self, for: body)?.motionType == .kinematic)
        #expect(abs((runtime.worldTransform(for: body)?.translation.y ?? 0) - 4) < 0.001)
    }

    @Test("Scene v2 remaps ragdoll body and joint entities")
    func serializationRoundTrip() throws {
        var original = SceneRuntime()
        let root = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "root"), for: root)
        let body = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "body"), for: body)
        let joint = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "joint"), for: joint)
        let offset = translationMatrix(SIMD3<Float>(0, 0.5, 0))
        _ = original.setComponent(Ragdoll(
            mode: .blended,
            blendWeight: 0.35,
            bones: [RagdollBoneMapping(
                boneName: "spine",
                paletteIndex: 3,
                bodyEntity: body,
                jointEntity: joint,
                bodyFromPalette: offset,
                isSimulationEnabled: false,
                blendWeight: 0.8
            )]
        ), for: root)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredRoot = try #require(restored.findEntity(named: "root"))
        let restoredBody = try #require(restored.findEntity(named: "body"))
        let restoredJoint = try #require(restored.findEntity(named: "joint"))
        let ragdoll = try #require(restored.component(Ragdoll.self, for: restoredRoot))
        #expect(ragdoll.mode == .blended)
        #expect(ragdoll.blendWeight == 0.35)
        #expect(ragdoll.bones.first?.bodyEntity == restoredBody)
        #expect(ragdoll.bones.first?.jointEntity == restoredJoint)
        #expect(ragdoll.bones.first?.bodyFromPalette == offset)
        #expect(ragdoll.bones.first?.isSimulationEnabled == false)
    }
}

private func translationMatrix(_ value: SIMD3<Float>) -> simd_float4x4 {
    var matrix = matrix_identity_float4x4
    matrix.columns.3 = SIMD4<Float>(value, 1)
    return matrix
}
