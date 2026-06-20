import SceneRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("Particles")
struct ParticleTests {

    @Test("continuous emission spawns at the configured rate")
    func continuousEmission() {
        var emitter = ParticleEmitter(emissionRate: 10, maxParticles: 1000, lifetime: 1000,
                                      startVelocity: .zero, gravity: .zero)
        for _ in 0..<10 { emitter.advance(deltaTime: 0.1) } // 10 * (10/s * 0.1s) = 10
        #expect(emitter.aliveCount == 10)
    }

    @Test("scheduled bursts spawn particles at configured intervals")
    func scheduledBursts() {
        var emitter = ParticleEmitter(emissionRate: 0, burstCount: 3, burstInterval: 0.5,
                                      maxParticles: 100, lifetime: 100,
                                      startVelocity: .zero, gravity: .zero)
        emitter.advance(deltaTime: 0.49)
        #expect(emitter.aliveCount == 0)
        emitter.advance(deltaTime: 0.01)
        #expect(emitter.aliveCount == 3)
        emitter.advance(deltaTime: 1.0)
        #expect(emitter.aliveCount == 9)
    }

    @Test("distance emission spawns particles after the emitter moves")
    func distanceEmission() {
        var start = matrix_identity_float4x4
        start.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(1, 0, 0, 1)
        var emitter = ParticleEmitter(emissionRate: 0,
                                      distanceEmissionRate: 4,
                                      maxParticles: 16,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      simulationSpace: .world)

        emitter.advance(deltaTime: 0.1, worldTransform: start)
        #expect(emitter.aliveCount == 0)

        emitter.advance(deltaTime: 0.1, worldTransform: moved)
        #expect(emitter.aliveCount == 4)
        #expect(emitter.particles.map(\.position.x) == [0.125, 0.375, 0.625, 0.875])
    }

    @Test("distance emission carries fractional movement between frames")
    func distanceEmissionAccumulator() {
        var start = matrix_identity_float4x4
        var moved = matrix_identity_float4x4
        var emitter = ParticleEmitter(emissionRate: 0,
                                      distanceEmissionRate: 2,
                                      maxParticles: 16,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      simulationSpace: .world)

        emitter.advance(deltaTime: 0.1, worldTransform: start)
        moved.columns.3 = SIMD4<Float>(0.25, 0, 0, 1)
        emitter.advance(deltaTime: 0.1, worldTransform: moved)
        #expect(emitter.aliveCount == 0)

        start.columns.3 = SIMD4<Float>(0.5, 0, 0, 1)
        emitter.advance(deltaTime: 0.1, worldTransform: start)
        #expect(emitter.aliveCount == 1)
    }

    @Test("spawned particles can inherit emitter velocity")
    func velocityInheritance() {
        let start = matrix_identity_float4x4
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(2, 0, 0, 1)
        var emitter = ParticleEmitter(emissionRate: 0,
                                      distanceEmissionRate: 1,
                                      maxParticles: 8,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      velocityInheritance: 0.5,
                                      gravity: .zero,
                                      simulationSpace: .world)

        emitter.advance(deltaTime: 1, worldTransform: start)
        emitter.advance(deltaTime: 1, worldTransform: moved)

        #expect(emitter.aliveCount == 2)
        #expect(emitter.particles.allSatisfy { $0.velocity == SIMD3<Float>(1, 0, 0) })
    }

    @Test("non-looping duration stops new emissions")
    func nonLoopingDurationStopsEmission() {
        var emitter = ParticleEmitter(looping: false, duration: 0.5,
                                      emissionRate: 10, maxParticles: 100, lifetime: 100,
                                      startVelocity: .zero, gravity: .zero)
        emitter.advance(deltaTime: 0.5)
        #expect(emitter.aliveCount == 5)
        emitter.advance(deltaTime: 1.0)
        #expect(emitter.aliveCount == 5)

        emitter.clear()
        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 1)
    }

    @Test("particles are culled once they exceed their lifetime")
    func lifetimeCulling() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 0.5, gravity: .zero)
        emitter.emit(3)
        #expect(emitter.aliveCount == 3)
        emitter.advance(deltaTime: 0.6) // age 0.6 > lifetime 0.5
        #expect(emitter.aliveCount == 0)
    }

    @Test("death sub-emitter spawns child particles with independent appearance")
    func deathSubEmitter() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 0.5,
                                      subEmitterTrigger: .death,
                                      subEmitterBurstCount: 2,
                                      subEmitterMaxDepth: 1,
                                      subEmitterLifetime: 2,
                                      subEmitterStartVelocity: SIMD3<Float>(1, 0, 0),
                                      subEmitterVelocityRandomness: .zero,
                                      subEmitterStartSize: 0.25,
                                      subEmitterEndSize: 0.25,
                                      subEmitterStartColor: SIMD4<Float>(1, 0, 0, 1),
                                      subEmitterEndColor: SIMD4<Float>(1, 0, 0, 1),
                                      startVelocity: .zero,
                                      gravity: .zero)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.6)

        #expect(emitter.aliveCount == 2)
        for child in emitter.particles {
            #expect(child.generation == 1)
            #expect(child.lifetime == 2)
            #expect(child.velocity == SIMD3<Float>(1, 0, 0))
            #expect(child.size == 0.25)
            #expect(child.color == SIMD4<Float>(1, 0, 0, 1))
        }

        emitter.advance(deltaTime: 2.1)
        #expect(emitter.aliveCount == 0)
    }

    @Test("multiple death sub-emitter rules spawn independent child appearances")
    func multipleDeathSubEmitters() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 0.5,
                                      subEmitters: [
                                          ParticleSubEmitter(trigger: .death,
                                                             burstCount: 1,
                                                             lifetime: 2,
                                                             startVelocity: SIMD3<Float>(1, 0, 0),
                                                             startSize: 0.2,
                                                             endSize: 0.2,
                                                             startColor: SIMD4<Float>(1, 0, 0, 1),
                                                             endColor: SIMD4<Float>(1, 0, 0, 1)),
                                          ParticleSubEmitter(trigger: .death,
                                                             burstCount: 2,
                                                             lifetime: 3,
                                                             startVelocity: SIMD3<Float>(0, 1, 0),
                                                             startSize: 0.4,
                                                             endSize: 0.4,
                                                             startColor: SIMD4<Float>(0, 0, 1, 1),
                                                             endColor: SIMD4<Float>(0, 0, 1, 1)),
                                      ],
                                      startVelocity: .zero,
                                      gravity: .zero)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.6)

        #expect(emitter.aliveCount == 3)
        let redChildren = emitter.particles.filter { $0.appearanceIndex == 2 }
        let blueChildren = emitter.particles.filter { $0.appearanceIndex == 3 }
        #expect(redChildren.count == 1)
        #expect(blueChildren.count == 2)
        #expect(redChildren.allSatisfy { $0.generation == 1 && $0.lifetime == 2 })
        #expect(redChildren.allSatisfy { $0.velocity == SIMD3<Float>(1, 0, 0) })
        #expect(redChildren.allSatisfy { $0.size == 0.2 && $0.color == SIMD4<Float>(1, 0, 0, 1) })
        #expect(blueChildren.allSatisfy { $0.generation == 1 && $0.lifetime == 3 })
        #expect(blueChildren.allSatisfy { $0.velocity == SIMD3<Float>(0, 1, 0) })
        #expect(blueChildren.allSatisfy { $0.size == 0.4 && $0.color == SIMD4<Float>(0, 0, 1, 1) })
    }

    @Test("collision sub-emitter spawns child particles at the collision point")
    func collisionSubEmitter() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 10,
                                      subEmitterTrigger: .collision,
                                      subEmitterBurstCount: 1,
                                      subEmitterLifetime: 2,
                                      subEmitterStartVelocity: SIMD3<Float>(2, 0, 0),
                                      subEmitterVelocityRandomness: .zero,
                                      originOffset: SIMD3<Float>(0, 0.5, 0),
                                      startVelocity: SIMD3<Float>(0, -1, 0),
                                      gravity: .zero,
                                      collisionMode: .localPlane,
                                      collisionPlaneY: 0,
                                      collisionRestitution: 0.5)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        #expect(emitter.aliveCount == 2)
        let parent = emitter.particles.first { $0.generation == 0 }
        let child = emitter.particles.first { $0.generation == 1 }
        #expect(parent != nil)
        #expect(child != nil)
        #expect(parent!.position.y == 0)
        #expect(abs(parent!.velocity.y - 0.5) < 1e-4)
        #expect(child!.position.y == 0)
        #expect(child!.velocity == SIMD3<Float>(2, 0, 0))
    }

    @Test("gravity and velocity integrate with semi-implicit Euler")
    func motionIntegration() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 100,
                                      spawnRadius: 0, startVelocity: .zero,
                                      gravity: SIMD3<Float>(0, -10, 0))
        emitter.emit(1)
        emitter.advance(deltaTime: 1)
        let p = emitter.particles[0]
        #expect(abs(p.velocity.y + 10) < 1e-4)   // v += g*dt → -10
        #expect(abs(p.position.y + 10) < 1e-4)   // p += v*dt → -10
    }

    @Test("radial force accelerates particles away from the force center")
    func radialForce() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      lifetime: 10,
                                      originOffset: SIMD3<Float>(1, 0, 0),
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      forceMode: .radial,
                                      forceRadius: 0,
                                      forceStrength: 2,
                                      forceFalloff: 0)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        #expect(abs(p.velocity.x - 2) < 1e-4)
        #expect(abs(p.position.x - 3) < 1e-4)
    }

    @Test("vortex force accelerates particles around the configured axis")
    func vortexForce() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      lifetime: 10,
                                      originOffset: SIMD3<Float>(1, 0, 0),
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      forceMode: .vortex,
                                      forceAxis: SIMD3<Float>(0, 1, 0),
                                      forceRadius: 0,
                                      forceStrength: 3,
                                      forceFalloff: 0)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        #expect(abs(p.velocity.z + 3) < 1e-4)
        #expect(abs(p.position.z + 3) < 1e-4)
    }

    @Test("maxParticles caps the live pool")
    func maxParticlesCap() {
        var emitter = ParticleEmitter(emissionRate: 10_000, maxParticles: 5, lifetime: 1000, gravity: .zero)
        for _ in 0..<10 { emitter.advance(deltaTime: 0.1) }
        #expect(emitter.aliveCount == 5)
        emitter.emit(100)
        #expect(emitter.aliveCount == 5)
    }

    @Test("identical seeds produce identical simulations")
    func deterministicWithSeed() {
        func run() -> [Particle] {
            var e = ParticleEmitter(emissionRate: 50, maxParticles: 64, lifetime: 5,
                                    spawnRadius: 1,
                                    velocityRandomness: SIMD3<Float>(2, 2, 2),
                                    gravity: SIMD3<Float>(0, -9.81, 0), seed: 42)
            for _ in 0..<20 { e.advance(deltaTime: 1.0 / 60.0) }
            return e.particles
        }
        #expect(run() == run())
    }

    @Test("box emission spawns within configured half extents")
    func boxEmissionShape() {
        var emitter = ParticleEmitter(emissionRate: 0, maxParticles: 64, lifetime: 10,
                                      emissionShape: .box,
                                      boxHalfExtents: SIMD3<Float>(2, 3, 4),
                                      startVelocity: .zero, gravity: .zero,
                                      seed: 7)
        emitter.emit(32)

        #expect(emitter.aliveCount == 32)
        for p in emitter.particles {
            #expect(abs(p.position.x) <= 2)
            #expect(abs(p.position.y) <= 3)
            #expect(abs(p.position.z) <= 4)
        }
    }

    @Test("cone emission spawns inside cone volume oriented by start velocity")
    func coneEmissionShape() {
        var emitter = ParticleEmitter(emissionRate: 0, maxParticles: 64, lifetime: 10,
                                      emissionShape: .cone,
                                      coneRadius: 2, coneHeight: 5,
                                      startVelocity: SIMD3<Float>(0, 1, 0),
                                      gravity: .zero, seed: 11)
        emitter.emit(32)

        #expect(emitter.aliveCount == 32)
        for p in emitter.particles {
            #expect(p.position.y >= 0)
            #expect(p.position.y <= 5)
            let radial = sqrt(p.position.x * p.position.x + p.position.z * p.position.z)
            let allowedRadius = 2 * (p.position.y / 5)
            #expect(radial <= allowedRadius + 0.0001)
        }
    }

    @Test("local plane collision bounces particles and damps tangent velocity")
    func localPlaneCollision() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 100,
                                      startVelocity: SIMD3<Float>(4, 0, 0),
                                      gravity: SIMD3<Float>(0, -10, 0),
                                      collisionMode: .localPlane,
                                      collisionPlaneY: 0,
                                      collisionRestitution: 0.5,
                                      collisionDamping: 0.25)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        #expect(abs(p.position.y) < 1e-4)
        #expect(abs(p.velocity.y - 5) < 1e-4)
        #expect(abs(p.velocity.x - 3) < 1e-4)
    }

    @Test("world plane collision uses the entity world transform")
    func worldPlaneCollision() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var worldMatrix = matrix_identity_float4x4
        worldMatrix.columns.3 = SIMD4<Float>(0, 5, 0, 1)
        _ = scene.setComponent(WorldTransform(matrix: worldMatrix), for: entity)

        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 100,
                                      startVelocity: SIMD3<Float>(4, 0, 0),
                                      gravity: SIMD3<Float>(0, -10, 0),
                                      collisionMode: .worldPlane,
                                      collisionPlaneY: 0,
                                      collisionRestitution: 0.5,
                                      collisionDamping: 0.25)
        emitter.emit(1)
        _ = scene.setComponent(emitter, for: entity)

        #expect(scene.advanceParticles(deltaTime: 1) == 1)

        let p = scene.component(ParticleEmitter.self, for: entity)!.particles[0]
        #expect(abs(p.position.y + 5) < 1e-4)
        #expect(abs(p.velocity.y - 5) < 1e-4)
        #expect(abs(p.velocity.x - 3) < 1e-4)
    }

    @Test("isEmitting=false stops new spawns but still ages live particles")
    func stoppedEmitterStillAges() {
        var emitter = ParticleEmitter(emissionRate: 100, lifetime: 0.5, gravity: .zero)
        emitter.emit(4)
        emitter.isEmitting = false
        #expect(emitter.aliveCount == 4)
        emitter.advance(deltaTime: 0.6)
        #expect(emitter.aliveCount == 0) // aged out, none replaced
    }

    @Test("appearance lerps from start to end across lifetime")
    func appearanceGradient() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 1, gravity: .zero,
                                      startSize: 2, endSize: 0,
                                      startColor: SIMD4<Float>(1, 1, 1, 1),
                                      endColor: SIMD4<Float>(1, 1, 1, 0))
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5) // halfway through life
        let p = emitter.particles[0]
        #expect(abs(p.size - 1) < 1e-4)        // lerp(2, 0, 0.5) = 1
        #expect(abs(p.color.w - 0.5) < 1e-4)   // alpha lerp(1, 0, 0.5) = 0.5
    }

    @Test("appearance curves remap normalized age for size and color")
    func appearanceCurves() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 1, gravity: .zero,
                                      startSize: 0, endSize: 1, sizeCurve: .easeIn,
                                      startColor: SIMD4<Float>(1, 1, 1, 0),
                                      endColor: SIMD4<Float>(1, 1, 1, 1),
                                      colorCurve: .easeOut)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5)

        let p = emitter.particles[0]
        #expect(abs(p.size - 0.25) < 1e-4)
        #expect(abs(p.color.w - 0.75) < 1e-4)
    }

    @Test("size randomness applies stable per-particle scales")
    func sizeRandomness() {
        func run() -> [Particle] {
            var emitter = ParticleEmitter(emissionRate: 0,
                                          maxParticles: 8,
                                          lifetime: 1,
                                          gravity: .zero,
                                          startSize: 2,
                                          endSize: 2,
                                          sizeRandomness: 0.5,
                                          seed: 99)
            emitter.emit(4)
            emitter.advance(deltaTime: 0.25)
            return emitter.particles
        }

        let particles = run()
        #expect(particles == run())
        #expect(particles.allSatisfy { $0.size >= 1 && $0.size <= 3 })
        #expect(particles.contains { abs($0.size - 2) > 0.0001 })
    }

    @Test("particle rotation integrates angular velocity")
    func particleRotation() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      maxParticles: 4,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      startRotation: 0.25,
                                      angularVelocity: 2)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5)

        let p = emitter.particles[0]
        #expect(abs(p.rotation - 1.25) < 1e-4)
        #expect(abs(p.angularVelocity - 2) < 1e-4)
    }

    @Test("world simulation space spawns and stores particles in world coordinates")
    func worldSimulationSpaceStoresWorldParticles() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 0, 0, 1)
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 4,
                                      lifetime: 10,
                                      originOffset: SIMD3<Float>(1, 0, 0),
                                      startVelocity: SIMD3<Float>(0, 2, 0),
                                      gravity: .zero,
                                      simulationSpace: .world)
        emitter.emit(1, worldTransform: transform)

        #expect(emitter.particles.count == 1)
        #expect(emitter.particles[0].position == SIMD3<Float>(11, 0, 0))
        #expect(emitter.particles[0].velocity == SIMD3<Float>(0, 2, 0))
        emitter.advance(deltaTime: 0.5, worldTransform: matrix_identity_float4x4)
        #expect(emitter.particles[0].position == SIMD3<Float>(11, 1, 0))
    }

    @Test("SceneRuntime.emitParticles passes entity transform for world-space emitters")
    func sceneEmitParticlesUsesWorldTransformForWorldSpaceEmitters() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: entity)
        scene.propagateTransforms()
        _ = scene.setComponent(
            ParticleEmitter(isEmitting: false,
                            emissionRate: 0,
                            maxParticles: 2,
                            lifetime: 10,
                            startVelocity: .zero,
                            gravity: .zero,
                            simulationSpace: .world),
            for: entity
        )

        let emitted = scene.emitParticles(from: entity, count: 1)
        #expect(emitted)
        #expect(scene.component(ParticleEmitter.self, for: entity)?.particles[0].position == SIMD3<Float>(4, 0, 0))
    }

    @Test("keyframe curves linearly interpolate sorted keys")
    func appearanceKeyframeCurves() {
        var emitter = ParticleEmitter(
            emissionRate: 0,
            lifetime: 1,
            gravity: .zero,
            startSize: 0,
            endSize: 10,
            sizeCurve: .keyframes([
                ParticleCurveKeyframe(time: 1, value: 0),
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 0.5, value: 1),
            ]),
            startColor: SIMD4<Float>(1, 1, 1, 0),
            endColor: SIMD4<Float>(1, 1, 1, 1),
            colorCurve: .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 0.5),
            ])
        )
        emitter.emit(1)
        emitter.advance(deltaTime: 0.25)

        let p = emitter.particles[0]
        #expect(abs(p.size - 5) < 1e-4)
        #expect(abs(p.color.w - 0.125) < 1e-4)
    }

    @Test("ParticleCurve evaluates presets and keyframes")
    func particleCurveEvaluation() {
        #expect(ParticleCurve.constant(2.5).evaluate(at: -1) == 2.5)
        #expect(ParticleCurve.constant(2.5).evaluate(at: 2) == 2.5)
        #expect(ParticleCurve.linear.evaluate(at: -1) == 0)
        #expect(ParticleCurve.linear.evaluate(at: 2) == 1)
        #expect(abs(ParticleCurve.easeIn.evaluate(at: 0.5) - 0.25) < 1e-4)
        #expect(abs(ParticleCurve.easeOut.evaluate(at: 0.5) - 0.75) < 1e-4)
        #expect(abs(ParticleCurve.easeInOut.evaluate(at: 0.25) - 0.125) < 1e-4)

        let curve = ParticleCurve.keyframes([
            ParticleCurveKeyframe(time: 1, value: 0),
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 0.5, value: 1),
        ])
        #expect(abs(curve.evaluate(at: 0.25) - 0.5) < 1e-4)
        #expect(abs(curve.evaluate(at: 0.75) - 0.5) < 1e-4)
    }

    @Test("emission rate curve modulates continuous spawn rate over emitter duration")
    func emissionRateCurveModulatesContinuousEmission() {
        var emitter = ParticleEmitter(
            looping: false,
            duration: 2,
            emissionRate: 10,
            emissionRateCurve: .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ]),
            maxParticles: 100,
            lifetime: 10,
            startVelocity: .zero,
            gravity: .zero
        )

        emitter.advance(deltaTime: 1)
        #expect(emitter.aliveCount == 5)
        emitter.advance(deltaTime: 1)
        #expect(emitter.aliveCount == 20)
    }

    @Test("distance emission rate curve modulates movement-based spawn rate")
    func distanceEmissionRateCurveModulatesDistanceEmission() {
        var emitter = ParticleEmitter(
            looping: false,
            duration: 2,
            emissionRate: 0,
            distanceEmissionRate: 10,
            distanceEmissionRateCurve: .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ]),
            maxParticles: 100,
            lifetime: 10,
            startVelocity: .zero,
            gravity: .zero,
            simulationSpace: .world
        )
        var transform = matrix_identity_float4x4

        emitter.advance(deltaTime: 0.01, worldTransform: transform)
        transform.columns.3.x = 1
        emitter.advance(deltaTime: 1, worldTransform: transform)
        #expect(emitter.aliveCount == 5)
        transform.columns.3.x = 2
        emitter.advance(deltaTime: 1, worldTransform: transform)
        #expect(emitter.aliveCount == 20)
    }

    @Test("prewarm simulates once before the first active tick")
    func prewarmSimulatesBeforeFirstTick() {
        var emitter = ParticleEmitter(
            prewarmTime: 1,
            prewarmStep: 0.5,
            emissionRate: 10,
            maxParticles: 100,
            lifetime: 10,
            startVelocity: .zero,
            gravity: .zero
        )

        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 11)
        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 12)

        emitter.clear()
        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 11)
    }

    @Test("texture sheet UV rect advances over lifetime or frame rate")
    func textureSheetUVRect() {
        var lifetimeEmitter = ParticleEmitter(emissionRate: 0,
                                              lifetime: 1,
                                              gravity: .zero,
                                              textureSheetColumns: 2,
                                              textureSheetRows: 2,
                                              textureSheetFrameCount: 4)
        lifetimeEmitter.emit(1)
        lifetimeEmitter.advance(deltaTime: 0.5)
        #expect(lifetimeEmitter.textureUVRect(for: lifetimeEmitter.particles[0]) == SIMD4<Float>(0, 0.5, 0.5, 0.5))

        var rateEmitter = ParticleEmitter(emissionRate: 0,
                                          lifetime: 10,
                                          gravity: .zero,
                                          textureSheetColumns: 4,
                                          textureSheetRows: 1,
                                          textureSheetFrameCount: 4,
                                          textureSheetFrameRate: 2)
        rateEmitter.emit(1)
        rateEmitter.advance(deltaTime: 1.5)
        #expect(rateEmitter.textureUVRect(for: rateEmitter.particles[0]) == SIMD4<Float>(0.75, 0, 0.25, 1))
    }

    @Test("trail configuration is sanitized at construction")
    func trailConfigurationSanitizes() {
        let emitter = ParticleEmitter(trailLength: -1,
                                      trailSegments: -4,
                                      trailEndSizeScale: -0.5,
                                      trailEndAlphaScale: 2)

        #expect(emitter.trailLength == 0)
        #expect(emitter.trailSegments == 0)
        #expect(emitter.trailEndSizeScale == 0)
        #expect(emitter.trailEndAlphaScale == 1)
    }

    @Test("noise force deterministically accelerates particles")
    func noiseForce() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 10,
                                      startVelocity: .zero, gravity: .zero,
                                      noiseStrength: 2, noiseScale: 1, noiseSpeed: 0,
                                      seed: 0)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        let expected = SIMD3<Float>(
            0,
            Float(sin(2.17)) * 2,
            Float(sin(4.31)) * 2
        )
        #expect(simd_length(p.velocity - expected) < 1e-4)
        #expect(simd_length(p.position - expected) < 1e-4)
    }

    @Test("SceneRuntime.advanceParticles steps every emitter component")
    func sceneAdvancesAllEmitters() {
        var scene = SceneRuntime()
        let a = scene.createEntity()
        let b = scene.createEntity()
        var e = ParticleEmitter(emissionRate: 10, maxParticles: 100, lifetime: 1000, gravity: .zero)
        e.emit(2)
        _ = scene.setComponent(e, for: a)
        _ = scene.setComponent(e, for: b)

        let stepped = scene.advanceParticles(deltaTime: 0.1)
        #expect(stepped == 2)
        #expect(scene.component(ParticleEmitter.self, for: a)!.aliveCount == 3) // 2 seeded + 1 emitted
        #expect(scene.component(ParticleEmitter.self, for: b)!.aliveCount == 3)
    }

    @Test("SceneRuntime.emitParticles triggers one emitter")
    func sceneEmitParticles() {
        var scene = SceneRuntime()
        let emitterEntity = scene.createEntity()
        let emptyEntity = scene.createEntity()
        _ = scene.setComponent(
            ParticleEmitter(emissionRate: 0, maxParticles: 5, lifetime: 10, gravity: .zero),
            for: emitterEntity
        )

        let emitted = scene.emitParticles(from: emitterEntity, count: 3)
        #expect(emitted)
        #expect(scene.component(ParticleEmitter.self, for: emitterEntity)!.aliveCount == 3)
        let missingEmitterEmitted = scene.emitParticles(from: emptyEntity, count: 3)
        #expect(!missingEmitterEmitted)
    }
}
