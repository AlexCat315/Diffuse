@testable import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat
import Testing

@Suite("EditorInspectorSections", .serialized)
struct EditorInspectorSectionsTests {

    private func makeEntity(in adapter: EditorSceneAdapter) -> UInt64 {
        adapter.scene.createEntity().rawValue
    }

    private func field(_ adapter: EditorSceneAdapter, _ rawID: UInt64,
                       section: String, field: String) -> EditorInspectorFieldValue? {
        for s in adapter.inspectorSections(for: rawID) where s.id == section {
            for f in s.fields where f.id == field { return f.value }
        }
        return nil
    }

    private func hasSection(_ adapter: EditorSceneAdapter, _ rawID: UInt64, _ id: String) -> Bool {
        adapter.inspectorSections(for: rawID).contains { $0.id == id }
    }

    // MARK: - Camera

    @Test("camera section appears only when the entity has a camera")
    func cameraSectionPresence() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(!hasSection(adapter, id, "camera"))
        _ = adapter.addComponent(.camera, to: id)
        #expect(hasSection(adapter, id, "camera"))
    }

    @Test("camera active binding writes back to the component")
    func cameraActiveBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .bool(binding) = field(adapter, id, section: "camera", field: "camera-active") else {
            Issue.record("expected camera-active bool field"); return
        }
        binding.wrappedValue = true
        #expect(adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.isActive == true)
    }

    @Test("camera FOV binding shows degrees and stores radians")
    func cameraFOVBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "camera", field: "camera-fov") else {
            Issue.record("expected camera-fov number field"); return
        }
        binding.wrappedValue = 90 // degrees
        let radians = adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.fovYRadians
        #expect(radians != nil)
        #expect(abs(radians! - .pi / 2) < 1e-4)
        // And the getter reflects it back in degrees.
        #expect(abs(binding.wrappedValue - 90) < 1e-3)
    }

    // MARK: - Audio Listener

    @Test("audio listener volume binding writes back")
    func audioListenerBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.audioListener, to: id)
        #expect(hasSection(adapter, id, "audio-listener"))

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "audio-listener", field: "audio-listener-volume") else {
            Issue.record("expected master volume field"); return
        }
        binding.wrappedValue = 0.25
        #expect(adapter.scene.component(AudioListener.self, for: EntityID(rawValue: id)!)?.masterVolume == 0.25)
    }

    // MARK: - Animation Graph

    @Test("animation graph definition JSON binding writes back")
    func animationGraphDefinitionBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = EntityID(rawValue: id)!
        _ = adapter.addComponent(.animationGraphPlayer, to: id)

        guard case let .json(binding, _) =
                field(adapter, id, section: "animation-graph-player", field: "anim-graph-definition") else {
            Issue.record("expected animation graph definition JSON field"); return
        }

        let graph = AnimationGraph(
            blendSpaces1D: [
                AnimationBlendSpace1D(name: "Locomotion",
                                      parameter: "speed",
                                      samples: [
                                        AnimationBlendSample1D(clipName: "idle", threshold: 0),
                                        AnimationBlendSample1D(clipName: "walk", threshold: 1),
                                      ]),
            ],
            stateMachine: AnimationStateMachine(
                initialState: "Move",
                states: [
                    AnimationState(name: "Move", motion: .blendSpace1D("Locomotion")),
                ]
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(graph)
        binding.wrappedValue = String(decoding: data, as: UTF8.self)

        let player = adapter.scene.component(AnimationGraphPlayer.self, for: entity)
        #expect(player?.graph == graph)
        #expect(player?.activeState == "Move")
        #expect(binding.wrappedValue.contains("\"blendSpace1D\""))
    }

    // MARK: - Particle Emitter

    @Test("particle emitter section appears with the component")
    func particleSectionPresence() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(!hasSection(adapter, id, "particle-emitter"))
        _ = adapter.addComponent(.particleEmitter, to: id)
        #expect(hasSection(adapter, id, "particle-emitter"))
    }

    @Test("particle scalar and bool bindings write back")
    func particleScalarBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = EntityID(rawValue: id)!

        if case let .constrainedNumber(rate, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rate") {
            rate.wrappedValue = 42
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionRate == 42)
        } else { Issue.record("missing rate field") }

        if case let .constrainedNumber(duration, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-duration") {
            duration.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.duration == 2.5)
        } else { Issue.record("missing duration field") }

        if case let .constrainedNumber(maxP, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max") {
            maxP.wrappedValue = 128
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxParticles == 128)
        } else { Issue.record("missing max field") }

        if case let .constrainedNumber(burstCount, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-burst-count") {
            burstCount.wrappedValue = 4.8
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.burstCount == 5)
        } else { Issue.record("missing burst count field") }

        if case let .constrainedNumber(burstInterval, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-burst-interval") {
            burstInterval.wrappedValue = 0.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.burstInterval == 0.25)
        } else { Issue.record("missing burst interval field") }

        if case let .bool(emitting) = field(adapter, id, section: "particle-emitter", field: "particle-emitting") {
            emitting.wrappedValue = false
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.isEmitting == false)
        } else { Issue.record("missing emitting field") }

        if case let .particleEmissionShape(shape) =
            field(adapter, id, section: "particle-emitter", field: "particle-shape") {
            shape.wrappedValue = .cone
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionShape == .cone)
        } else { Issue.record("missing shape field") }

        if case let .particleCollisionMode(mode) =
            field(adapter, id, section: "particle-emitter", field: "particle-collision-mode") {
            mode.wrappedValue = .worldPlane
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.collisionMode == .worldPlane)
        } else { Issue.record("missing collision mode field") }

        if case let .constrainedNumber(restitution, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-collision-restitution") {
            restitution.wrappedValue = 0.7
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.collisionRestitution == 0.7)
        } else { Issue.record("missing restitution field") }

        if case let .constrainedNumber(noiseStrength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-noise-strength") {
            noiseStrength.wrappedValue = 1.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.noiseStrength == 1.5)
        } else { Issue.record("missing noise strength field") }

        if case let .constrainedNumber(noiseScale, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-noise-scale") {
            noiseScale.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.noiseScale == 2.5)
        } else { Issue.record("missing noise scale field") }

        if case let .constrainedNumber(noiseSpeed, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-noise-speed") {
            noiseSpeed.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.noiseSpeed == 0.75)
        } else { Issue.record("missing noise speed field") }

        if case let .particleCurve(sizeCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-size-curve") {
            sizeCurve.wrappedValue = .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 1),
            ])
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.sizeCurve == .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 1),
            ]))
        } else { Issue.record("missing size curve field") }

        if case let .constrainedNumber(sizeRandomness, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-size-randomness") {
            sizeRandomness.wrappedValue = 0.3
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.sizeRandomness == 0.3)
        } else { Issue.record("missing size randomness field") }

        if case let .particleCurve(colorCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-color-curve") {
            colorCurve.wrappedValue = .easeOut
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.colorCurve == .easeOut)
        } else { Issue.record("missing color curve field") }

        if case let .particleBlendMode(blendMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-blend-mode") {
            blendMode.wrappedValue = .additive
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.blendMode == .additive)
        } else { Issue.record("missing blend mode field") }
    }

    @Test("particle gravity vector and color bindings write back")
    func particleVectorAndColorBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = EntityID(rawValue: id)!

        guard case let .vector3(gx, gy, gz) =
                field(adapter, id, section: "particle-emitter", field: "particle-gravity") else {
            Issue.record("expected gravity vector3"); return
        }
        gx.wrappedValue = 1; gy.wrappedValue = -20; gz.wrappedValue = 3
        let g = adapter.scene.component(ParticleEmitter.self, for: entity)?.gravity
        #expect(g == SIMD3<Float>(1, -20, 3))

        guard case let .vector3(bx, by, bz) =
                field(adapter, id, section: "particle-emitter", field: "particle-box-extents") else {
            Issue.record("expected box extents vector3"); return
        }
        bx.wrappedValue = 2; by.wrappedValue = 3; bz.wrappedValue = 4
        let box = adapter.scene.component(ParticleEmitter.self, for: entity)?.boxHalfExtents
        #expect(box == SIMD3<Float>(2, 3, 4))

        guard case let .color(start) =
                field(adapter, id, section: "particle-emitter", field: "particle-start-color") else {
            Issue.record("expected start color"); return
        }
        start.wrappedValue = Color(r: 1, g: 0, b: 0, a: 1)
        let c = adapter.scene.component(ParticleEmitter.self, for: entity)?.startColor
        #expect(c == SIMD4<Float>(1, 0, 0, 1))
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF), generation: UInt32(rawValue >> 32))
    }
}
