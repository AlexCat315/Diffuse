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

    @Test("camera aspect binding writes back to the component")
    func cameraAspectBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "camera", field: "camera-aspect") else {
            Issue.record("expected camera-aspect number field"); return
        }
        binding.wrappedValue = 1.777
        let aspect = adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.aspectRatio
        #expect(aspect != nil)
        #expect(abs(aspect! - 1.777) < 1e-4)
        #expect(abs(binding.wrappedValue - 1.777) < 1e-4)
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
        #expect(hasSection(adapter, id, "particle-scalability"))
        _ = adapter.addComponent(.particleEmitter, to: id)
        #expect(hasSection(adapter, id, "particle-emitter"))
    }

    @Test("particle scalability bindings write scene resources")
    func particleScalabilityBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)

        guard case let .constrainedNumber(emissionScale, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-scale-emission") else {
            Issue.record("expected emission scale field"); return
        }
        emissionScale.wrappedValue = 0.5
        #expect(adapter.scene.resource(ParticleScalabilityResource.self)?.emissionScale == 0.5)

        guard case let .constrainedNumber(liveCapScale, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-scale-live-cap") else {
            Issue.record("expected live cap scale field"); return
        }
        liveCapScale.wrappedValue = 0.25
        #expect(adapter.scene.resource(ParticleScalabilityResource.self)?.maxLiveParticleScale == 0.25)

        guard case let .bool(enabled) =
                field(adapter, id, section: "particle-scalability", field: "particle-policy-enabled") else {
            Issue.record("expected policy enabled field"); return
        }
        enabled.wrappedValue = true
        #expect(adapter.scene.resource(ParticleScalabilityPolicyResource.self)?.isEnabled == true)

        guard case let .constrainedNumber(targetLive, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-policy-target-live") else {
            Issue.record("expected target live field"); return
        }
        targetLive.wrappedValue = 12_345
        #expect(adapter.scene.resource(ParticleScalabilityPolicyResource.self)?.targetLiveParticles == 12_345)

        guard case let .constrainedNumber(minimumScale, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-policy-min-scale") else {
            Issue.record("expected minimum scale field"); return
        }
        minimumScale.wrappedValue = 1.5
        #expect(adapter.scene.resource(ParticleScalabilityPolicyResource.self)?.minimumScale == 1)
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

        if case let .particleCurve(rateCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-rate-curve") {
            rateCurve.wrappedValue = .constant(1.5)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionRateCurve == .constant(1.5))
        } else { Issue.record("missing rate curve field") }

        if case let .constrainedNumber(duration, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-duration") {
            duration.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.duration == 2.5)
        } else { Issue.record("missing duration field") }

        if case let .constrainedNumber(prewarm, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-prewarm-time") {
            prewarm.wrappedValue = 1.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.prewarmTime == 1.25)
        } else { Issue.record("missing prewarm field") }

        if case let .constrainedNumber(prewarmStep, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-prewarm-step") {
            prewarmStep.wrappedValue = 0.05
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.prewarmStep == 0.05)
        } else { Issue.record("missing prewarm step field") }

        if case let .constrainedNumber(maxP, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max") {
            maxP.wrappedValue = 128
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxParticles == 128)
        } else { Issue.record("missing max field") }

        if case let .constrainedNumber(maxRendered, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max-rendered") {
            maxRendered.wrappedValue = 64
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxRenderedParticles == 64)
        } else { Issue.record("missing max rendered field") }

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

        if case let .constrainedNumber(distanceRate, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-distance-rate") {
            distanceRate.wrappedValue = 12
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.distanceEmissionRate == 12)
        } else { Issue.record("missing distance emission field") }

        if case let .particleCurve(distanceRateCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-distance-rate-curve") {
            distanceRateCurve.wrappedValue = .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ])
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.distanceEmissionRateCurve == .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ]))
        } else { Issue.record("missing distance rate curve field") }

        if case let .particleSubEmitterTrigger(trigger) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-trigger") {
            trigger.wrappedValue = .collision
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterTrigger == .collision)
        } else { Issue.record("missing sub-emitter trigger field") }

        if case let .constrainedNumber(subCount, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-burst") {
            subCount.wrappedValue = 3.8
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterBurstCount == 4)
        } else { Issue.record("missing sub-emitter count field") }

        if case let .constrainedNumber(subChance, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-probability") {
            subChance.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterProbability == 0.75)
        } else { Issue.record("missing sub-emitter chance field") }

        if case let .constrainedNumber(subDepth, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-depth") {
            subDepth.wrappedValue = 2.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterMaxDepth == 2)
        } else { Issue.record("missing sub-emitter depth field") }

        if case let .constrainedNumber(subInherit, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-inherit") {
            subInherit.wrappedValue = 0.45
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterInheritVelocity == 0.45)
        } else { Issue.record("missing sub-emitter inherit field") }

        if case let .constrainedNumber(subLifetime, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-lifetime") {
            subLifetime.wrappedValue = 0.6
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterLifetime == 0.6)
        } else { Issue.record("missing sub-emitter lifetime field") }

        if case let .constrainedNumber(subStartSize, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-start-size") {
            subStartSize.wrappedValue = 0.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterStartSize == 0.2)
        } else { Issue.record("missing sub-emitter start size field") }

        if case let .constrainedNumber(subEndSize, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-end-size") {
            subEndSize.wrappedValue = 0.05
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterEndSize == 0.05)
        } else { Issue.record("missing sub-emitter end size field") }

        if case let .particleSubEmitters(subEmitters) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitters") {
            #expect(subEmitters.wrappedValue.isEmpty)

            subEmitters.wrappedValue = [
                ParticleSubEmitter(trigger: .death,
                                   burstCount: 4,
                                   probability: 0.5,
                                   maxDepth: 1,
                                   inheritVelocity: 0.25,
                                   lifetime: 0.4,
                                   startVelocity: SIMD3<Float>(0, 1, 0),
                                   velocityRandomness: SIMD3<Float>(0.1, 0.2, 0.3),
                                   startSize: 0.3,
                                   endSize: 0.1,
                                   startColor: SIMD4<Float>(1, 0.5, 0.25, 1),
                                   endColor: SIMD4<Float>(1, 0.2, 0.1, 0)),
                ParticleSubEmitter(trigger: .collision,
                                   burstCount: 2,
                                   probability: 1,
                                   maxDepth: 2,
                                   inheritVelocity: 0,
                                   lifetime: 0.2,
                                   startVelocity: SIMD3<Float>(1, 0, 0),
                                   velocityRandomness: .zero,
                                   startSize: 0.2,
                                   endSize: 0,
                                   startColor: SIMD4<Float>(0.2, 0.4, 1, 1),
                                   endColor: SIMD4<Float>(0.2, 0.4, 1, 0)),
            ]
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters.count == 2)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters[0].trigger == .death)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters[1].trigger == .collision)

            var edited = subEmitters.wrappedValue
            edited[0].burstCount = -3
            edited[0].probability = 2
            edited[0].maxDepth = -1
            edited[0].inheritVelocity = -0.25
            edited[0].lifetime = -2
            edited[0].startSize = -1
            edited[0].endSize = -1
            edited.removeLast()
            subEmitters.wrappedValue = edited

            let stored = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters
            #expect(stored?.count == 1)
            #expect(stored?[0].burstCount == 0)
            #expect(stored?[0].probability == 1)
            #expect(stored?[0].maxDepth == 0)
            #expect(stored?[0].inheritVelocity == 0)
            #expect(stored?[0].lifetime == 0.0001)
            #expect(stored?[0].startSize == 0)
            #expect(stored?[0].endSize == 0)

            subEmitters.wrappedValue = []
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters.isEmpty == true)
        } else { Issue.record("missing particle sub-emitters field") }

        if case let .constrainedNumber(sheetColumns, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-columns") {
            sheetColumns.wrappedValue = 4
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetColumns == 4)
        } else { Issue.record("missing texture sheet columns field") }

        if case let .constrainedNumber(sheetRows, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-rows") {
            sheetRows.wrappedValue = 2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetRows == 2)
        } else { Issue.record("missing texture sheet rows field") }

        if case let .constrainedNumber(sheetFrames, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-frames") {
            sheetFrames.wrappedValue = 7.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetFrameCount == 7)
        } else { Issue.record("missing texture sheet frame field") }

        if case let .constrainedNumber(sheetFPS, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-fps") {
            sheetFPS.wrappedValue = 12
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetFrameRate == 12)
        } else { Issue.record("missing texture sheet fps field") }

        if case let .constrainedNumber(trailLength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-length") {
            trailLength.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailLength == 0.75)
        } else { Issue.record("missing trail length field") }

        if case let .constrainedNumber(trailSegments, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-segments") {
            trailSegments.wrappedValue = 6.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailSegments == 6)
        } else { Issue.record("missing trail segments field") }

        if case let .constrainedNumber(trailEndSize, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-end-size") {
            trailEndSize.wrappedValue = 0.35
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailEndSizeScale == 0.35)
        } else { Issue.record("missing trail end size field") }

        if case let .constrainedNumber(trailEndAlpha, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-end-alpha") {
            trailEndAlpha.wrappedValue = 0.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailEndAlphaScale == 0.2)
        } else { Issue.record("missing trail end alpha field") }

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

        if case let .particleSimulationSpace(space) =
            field(adapter, id, section: "particle-emitter", field: "particle-simulation-space") {
            space.wrappedValue = .world
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.simulationSpace == .world)
        } else { Issue.record("missing simulation space field") }

        if case let .particleSimulationBackend(backend) =
            field(adapter, id, section: "particle-emitter", field: "particle-simulation-backend") {
            backend.wrappedValue = .gpuRequired
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.simulationBackend == .gpuRequired)
        } else { Issue.record("missing simulation backend field") }

        if case let .constrainedNumber(workgroupSize, minimum, maximum, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-gpu-workgroup-size") {
            #expect(minimum == 1)
            #expect(maximum == Float(ParticleGPUSimulationPlan.maximumWorkgroupSize))
            workgroupSize.wrappedValue = 128
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.gpuSimulationWorkgroupSize == 128)
        } else { Issue.record("missing GPU workgroup field") }

        if case let .readOnly(gpuStatus) =
            field(adapter, id, section: "particle-emitter", field: "particle-gpu-status") {
            #expect(gpuStatus.contains("Unsupported"))
            #expect(gpuStatus.contains("collisions"))
        } else { Issue.record("missing GPU status field") }

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

        if case let .particleForceMode(forceMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-mode") {
            forceMode.wrappedValue = .vortex
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceMode == .vortex)
        } else { Issue.record("missing force mode field") }

        if case let .constrainedNumber(forceRadius, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-radius") {
            forceRadius.wrappedValue = 12
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceRadius == 12)
        } else { Issue.record("missing force radius field") }

        if case let .constrainedNumber(forceStrength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-strength") {
            forceStrength.wrappedValue = -3.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceStrength == -3.5)
        } else { Issue.record("missing force strength field") }

        if case let .constrainedNumber(forceFalloff, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-falloff") {
            forceFalloff.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceFalloff == 2.5)
        } else { Issue.record("missing force falloff field") }

        if case let .particleVectorFieldMode(vectorFieldMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-mode") {
            vectorFieldMode.wrappedValue = .curl
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldMode == .curl)
        } else { Issue.record("missing vector field mode field") }

        if case let .vector3(x, y, z) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-direction") {
            x.wrappedValue = 0
            y.wrappedValue = 0
            z.wrappedValue = 1
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldDirection
                    == SIMD3<Float>(0, 0, 1))
        } else { Issue.record("missing vector field direction field") }

        if case let .constrainedNumber(vectorFieldStrength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-strength") {
            vectorFieldStrength.wrappedValue = 6.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldStrength == 6.5)
        } else { Issue.record("missing vector field strength field") }

        if case let .constrainedNumber(vectorFieldScale, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-scale") {
            vectorFieldScale.wrappedValue = 2.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldScale == 2.25)
        } else { Issue.record("missing vector field scale field") }

        if case let .constrainedNumber(vectorFieldScroll, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-scroll") {
            vectorFieldScroll.wrappedValue = 0.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldScrollSpeed == 0.5)
        } else { Issue.record("missing vector field scroll field") }

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

        if case let .constrainedNumber(rotation, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rotation") {
            rotation.wrappedValue = 0.4
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.startRotation == 0.4)
        } else { Issue.record("missing rotation field") }

        if case let .constrainedNumber(rotationRandom, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rotation-randomness") {
            rotationRandom.wrappedValue = 0.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.rotationRandomness == 0.2)
        } else { Issue.record("missing rotation randomness field") }

        if case let .constrainedNumber(spin, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-angular-velocity") {
            spin.wrappedValue = 1.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.angularVelocity == 1.5)
        } else { Issue.record("missing angular velocity field") }

        if case let .constrainedNumber(spinRandom, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-angular-velocity-randomness") {
            spinRandom.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.angularVelocityRandomness == 0.75)
        } else { Issue.record("missing angular velocity randomness field") }

        if case let .constrainedNumber(velocityInheritance, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-velocity-inheritance") {
            velocityInheritance.wrappedValue = 0.4
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.velocityInheritance == 0.4)
        } else { Issue.record("missing velocity inheritance field") }

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

        if case let .particleRenderAlignment(alignment) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-alignment") {
            alignment.wrappedValue = .velocity
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderAlignment == .velocity)
        } else { Issue.record("missing render alignment field") }

        if case let .constrainedNumber(velocityStretch, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-velocity-stretch-scale") {
            velocityStretch.wrappedValue = 0.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.velocityStretchScale == 0.5)
        } else { Issue.record("missing velocity stretch field") }

        if case let .constrainedNumber(maxStretch, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-velocity-stretch-max") {
            maxStretch.wrappedValue = 6
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.velocityStretchMax == 6)
        } else { Issue.record("missing max stretch field") }

        if case let .constrainedNumber(maxRenderDistance, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max-render-distance") {
            maxRenderDistance.wrappedValue = 120
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxRenderDistance == 120)
        } else { Issue.record("missing max render distance field") }

        if case let .constrainedNumber(distanceFade, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-distance-fade") {
            distanceFade.wrappedValue = 24
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderDistanceFadeRange == 24)
        } else { Issue.record("missing render distance fade field") }

        if case let .constrainedNumber(lodStart, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-lod-start") {
            lodStart.wrappedValue = 40
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderLODStartDistance == 40)
        } else { Issue.record("missing render LOD start field") }

        if case let .constrainedNumber(lodEnd, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-lod-end") {
            lodEnd.wrappedValue = 120
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderLODEndDistance == 120)
        } else { Issue.record("missing render LOD end field") }

        if case let .constrainedNumber(lodScale, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-lod-min-scale") {
            lodScale.wrappedValue = 0.3
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderLODMinParticleScale == 0.3)
        } else { Issue.record("missing render LOD scale field") }

        if case let .particleRenderBoundsMode(boundsMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-bounds-mode") {
            boundsMode.wrappedValue = .automatic
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderBoundsMode == .automatic)
        } else { Issue.record("missing render bounds mode field") }

        if case let .constrainedNumber(boundsRadius, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-bounds-radius") {
            boundsRadius.wrappedValue = 48
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderBoundsRadius == 48)
        } else { Issue.record("missing render bounds radius field") }

        if case let .readOnly(estimate) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-bounds-estimate") {
            #expect(!estimate.isEmpty)
        } else { Issue.record("missing render bounds estimate field") }

        if case let .asset(textureAsset, acceptedKinds, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture") {
            #expect(acceptedKinds == ["Texture"])
            textureAsset.wrappedValue = EditorInspectorAssetRef(id: "Assets/Textures/smoke.png",
                                                                name: "smoke",
                                                                subtitle: "/tmp/particle-smoke.png",
                                                                kind: "Texture")
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureAssetID == "Assets/Textures/smoke.png")
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.texturePath == "/tmp/particle-smoke.png")
            textureAsset.wrappedValue = nil
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureAssetID == nil)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.texturePath == nil)
        } else { Issue.record("missing particle texture asset field") }
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

        guard case let .vector3(fcx, fcy, fcz) =
                field(adapter, id, section: "particle-emitter", field: "particle-force-center") else {
            Issue.record("expected force center vector3"); return
        }
        fcx.wrappedValue = 1; fcy.wrappedValue = 2; fcz.wrappedValue = 3
        let center = adapter.scene.component(ParticleEmitter.self, for: entity)?.forceCenter
        #expect(center == SIMD3<Float>(1, 2, 3))

        guard case let .vector3(fax, fay, faz) =
                field(adapter, id, section: "particle-emitter", field: "particle-force-axis") else {
            Issue.record("expected force axis vector3"); return
        }
        fax.wrappedValue = 0; fay.wrappedValue = 1; faz.wrappedValue = 0
        let axis = adapter.scene.component(ParticleEmitter.self, for: entity)?.forceAxis
        #expect(axis == SIMD3<Float>(0, 1, 0))

        guard case let .vector3(svx, svy, svz) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-velocity") else {
            Issue.record("expected sub-emitter velocity vector3"); return
        }
        svx.wrappedValue = 1; svy.wrappedValue = 2; svz.wrappedValue = 3
        let subVelocity = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterStartVelocity
        #expect(subVelocity == SIMD3<Float>(1, 2, 3))

        guard case let .vector3(srx, sry, srz) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-velocity-random") else {
            Issue.record("expected sub-emitter velocity random vector3"); return
        }
        srx.wrappedValue = 0.1; sry.wrappedValue = 0.2; srz.wrappedValue = 0.3
        let subRandom = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterVelocityRandomness
        #expect(subRandom == SIMD3<Float>(0.1, 0.2, 0.3))

        guard case let .color(subStart) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-start-color") else {
            Issue.record("expected sub-emitter start color"); return
        }
        subStart.wrappedValue = Color(r: 1, g: 0.5, b: 0, a: 1)
        let subStartColor = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterStartColor
        #expect(subStartColor == SIMD4<Float>(1, 0.5, 0, 1))

        guard case let .color(subEnd) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-end-color") else {
            Issue.record("expected sub-emitter end color"); return
        }
        subEnd.wrappedValue = Color(r: 1, g: 0, b: 0, a: 0)
        let subEndColor = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterEndColor
        #expect(subEndColor == SIMD4<Float>(1, 0, 0, 0))

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
