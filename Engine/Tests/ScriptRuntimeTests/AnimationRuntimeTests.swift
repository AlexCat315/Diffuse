import AssetPipeline
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing

@Suite("AnimationRuntime", .serialized)
struct AnimationRuntimeTests {

    // MARK: - Helpers

    private static func makeOneJointMesh(clipDuration: Float = 1.0) -> MeshAsset {
        let sampler = MeshAnimationSampler(
            inputTimes: [0, clipDuration],
            outputValues: [
                SIMD4<Float>(0, 0, 0, 0),
                SIMD4<Float>(1, 0, 0, 0),
            ]
        )
        let channel = MeshAnimationChannel(samplerIndex: 0, targetNodeIndex: 0, path: .translation)
        let clip = MeshAnimation(name: "walk", samplers: [sampler], channels: [channel])
        return MeshAsset(
            name: "test_skinned",
            vertices: [],
            indices: [],
            nodes: [MeshNode(name: "root")],
            skins: [MeshSkin(jointNodeIndices: [0],
                             inverseBindMatrices: [matrix_identity_float4x4])],
            animations: [clip]
        )
    }

    private static func makeScene(meshIndex: Int) -> (SceneRuntime, EntityID) {
        var runtime = SceneRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(AnimationPlayer(), for: entity)
        _ = runtime.setComponent(
            AssetReferenceComponent(
                assetID: "test:\(meshIndex)",
                name: "test",
                relativePath: "test.gltf",
                absolutePath: "/test.gltf",
                kind: "gltf",
                meshIndex: meshIndex
            ),
            for: entity
        )
        return (runtime, entity)
    }

    private static let testMeshBase = 200

    // MARK: - Time advancement

    @Test("animation time advances each tick when isPlaying is true")
    func timeAdvancesWhenPlaying() {
        let idx = Self.testMeshBase
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(), at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(isPlaying: true), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        let player = runtime.component(AnimationPlayer.self, for: entity)
        #expect((player?.time ?? 0) > 0)
    }

    @Test("animation time does not advance when isPlaying is false")
    func timeDoesNotAdvanceWhenPaused() {
        let idx = Self.testMeshBase + 1
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(), at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(isPlaying: false, time: 0.5), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        let player = runtime.component(AnimationPlayer.self, for: entity)
        #expect(player?.time == 0.5)
    }

    // MARK: - Loop behaviour

    @Test("looping clip wraps time at clip duration")
    func loopingClipWrapsTime() {
        let idx = Self.testMeshBase + 2
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(clipDuration: 1.0), at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(loop: true, isPlaying: true, time: 0.95), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        let t = runtime.component(AnimationPlayer.self, for: entity)?.time ?? 1.0
        #expect(t < 0.2)
    }

    @Test("non-looping clip clamps and stops at end")
    func nonLoopingClipStopsAtEnd() {
        let idx = Self.testMeshBase + 3
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(clipDuration: 1.0), at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(loop: false, isPlaying: true, time: 0.98), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        let player = runtime.component(AnimationPlayer.self, for: entity)
        #expect(player?.isPlaying == false)
        #expect((player?.time ?? 0) >= 1.0)
    }

    // MARK: - JointPalette resource

    @Test("JointPaletteMap resource is written after tick for entity with skin")
    func jointPaletteWrittenForSkinnedEntity() {
        let idx = Self.testMeshBase + 4
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(), at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(isPlaying: true), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        let palette = runtime.resource(JointPaletteMap.self)
        #expect(palette != nil)
        #expect(palette?.palette(for: entity) != nil)
        #expect(palette?.palette(for: entity)?.matrices.isEmpty == false)
    }

    @Test("entity without AnimationPlayer is skipped and palette has no entry")
    func entityWithoutPlayerIsSkipped() {
        let idx = Self.testMeshBase + 5
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(), at: idx)
        defer { AssetRegistry.shared.reset() }

        var runtime = SceneRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(
            AssetReferenceComponent(
                assetID: "test:\(idx)",
                name: "test",
                relativePath: "test.gltf",
                absolutePath: "/test.gltf",
                kind: "gltf",
                meshIndex: idx
            ),
            for: entity
        )

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        #expect(runtime.resource(JointPaletteMap.self)?.palette(for: entity) == nil)
    }

    // MARK: - Clip selection

    @Test("clipName selects named clip over first clip")
    func clipNameSelectsNamedClip() {
        let idx = Self.testMeshBase + 6
        let sampler = MeshAnimationSampler(
            inputTimes: [0, 2.0],
            outputValues: [SIMD4<Float>(0, 0, 0, 0), SIMD4<Float>(0, 2, 0, 0)]
        )
        let channel = MeshAnimationChannel(samplerIndex: 0, targetNodeIndex: 0, path: .translation)
        let mesh = MeshAsset(
            name: "hero",
            vertices: [],
            indices: [],
            nodes: [MeshNode(name: "root")],
            skins: [MeshSkin(jointNodeIndices: [0],
                             inverseBindMatrices: [matrix_identity_float4x4])],
            animations: [
                MeshAnimation(name: "idle", samplers: [sampler], channels: [channel]),
                MeshAnimation(name: "run",  samplers: [sampler], channels: [channel]),
            ]
        )
        AssetRegistry.shared.registerForTesting(mesh, at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(clipName: "run", isPlaying: true), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.1)

        #expect((runtime.component(AnimationPlayer.self, for: entity)?.time ?? 0) > 0)
        #expect(runtime.resource(JointPaletteMap.self)?.palette(for: entity) != nil)
    }

    // MARK: - SceneRuntime.runScriptDriver integration

    @Test("runScriptDriver drives AnimationRuntime and writes JointPaletteMap to scene")
    func runScriptDriverWritesPaletteMap() {
        let idx = Self.testMeshBase + 7
        AssetRegistry.shared.registerForTesting(Self.makeOneJointMesh(), at: idx)
        defer { AssetRegistry.shared.reset() }

        var (runtime, entity) = Self.makeScene(meshIndex: idx)
        _ = runtime.setComponent(AnimationPlayer(isPlaying: true), for: entity)

        runtime.runScriptDriver(AnimationRuntime(), deltaTime: 0.016)

        #expect(runtime.resource(JointPaletteMap.self)?.palette(for: entity) != nil)
    }
}
