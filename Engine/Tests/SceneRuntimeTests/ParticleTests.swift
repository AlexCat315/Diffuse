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
}
