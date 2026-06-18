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
