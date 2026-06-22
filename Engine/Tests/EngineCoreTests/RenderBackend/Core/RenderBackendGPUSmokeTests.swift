import Foundation
import RHIWGPU
import SceneRuntime
import Testing
import SIMDCompat
@testable import RenderBackend

private let gpuSmokeEnabled = ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] == "1"

@Suite("RenderBackendGPUSmoke", .serialized)
struct RenderBackendGPUSmokeTests {
    @Test("GPU particle event records convert to runtime particle events")
    func gpuParticleEventRecordsConvertToRuntimeParticleEvents() {
        let snapshot = GPUParticleSimulationEventSnapshot(
            slot: 0,
            emitterRawValue: 42,
            eventCapacity: 3,
            totalEventCount: 2,
            droppedEventCount: 0,
            records: [
                GPUParticleSimulationEventRecord(
                    trigger: .death,
                    sourceIndex: 7,
                    position: SIMD3<Float>(1, 2, 3),
                    lifetime: 4,
                    velocity: SIMD3<Float>(5, 6, 7),
                    age: 1.5,
                    generation: 2,
                    appearanceIndex: 9
                ),
                GPUParticleSimulationEventRecord(
                    trigger: .unknown,
                    sourceIndex: 8,
                    position: .zero,
                    lifetime: 1,
                    velocity: .zero,
                    age: 0
                ),
            ]
        )

        let events = snapshot.makeParticleEvents()

        #expect(events.count == 1)
        #expect(events[0].trigger == .death)
        #expect(events[0].position == SIMD3<Float>(1, 2, 3))
        #expect(events[0].velocity == SIMD3<Float>(5, 6, 7))
        #expect(events[0].age == 1.5)
        #expect(events[0].lifetime == 4)
        #expect(events[0].generation == 2)
        #expect(events[0].appearanceIndex == 9)
    }

    @Test("renders the scene contract into a readable WGPU framebuffer",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU smoke test"))
    func rendersSceneContractIntoFramebuffer() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        let packet = RenderPacket(
            frameIndex: 0,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: width, height: height),
            scene: Self.makeSmokeScene(),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 0
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.viewportResolve))
        #expect(stats.drawCallCount == 2)
        #expect(stats.passDrawCallCounts[.depthPrepass] == 1)
        #expect(stats.passDrawCallCounts[.basePass] == 1)

        let viewport = renderer.currentViewportSurfaceState()
        #expect(viewport.isValid)
        #expect(viewport.width == width)
        #expect(viewport.height == height)

        guard let texture = renderer.offscreenColorTexture else {
            Issue.record("expected renderer to retain an offscreen color texture")
            return
        }

        let pixels = try readbackBGRA8(
            texture: texture,
            width: width,
            height: height,
            backend: backend
        )
        try writeDebugPPMIfRequested(pixels: pixels, width: width, height: height)

        let background = BGRAPixel(
            r: UInt8(0.05 * 255.0),
            g: UInt8(0.06 * 255.0),
            b: UInt8(0.08 * 255.0),
            a: 255
        )
        let center = pixels[Int(height / 2) * Int(width) + Int(width / 2)]
        #expect(center.distance(from: background) > 48)

        let coveredPixels = pixels.count { pixel in
            pixel.a > 0 && pixel.distance(from: background) > 48
        }
        #expect(coveredPixels > Int(width * height) / 32)
    }

    @Test("particle billboard pass paints the framebuffer",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle smoke test"))
    func particlePassPaintsFramebuffer() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        let packet = RenderPacket(
            frameIndex: 0,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: width, height: height),
            scene: Self.makeParticleScene(),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 0
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.particles))
        #expect(stats.passDrawCallCounts[.particles] == 2)

        guard let texture = renderer.offscreenColorTexture else {
            Issue.record("expected renderer to retain an offscreen color texture")
            return
        }

        let pixels = try readbackBGRA8(texture: texture, width: width, height: height, backend: backend)
        try writeDebugPPMIfRequested(pixels: pixels, width: width, height: height)

        // Bluish clear color; the billboard is bright orange and covers the center.
        let background = BGRAPixel(
            r: UInt8(0.05 * 255.0),
            g: UInt8(0.06 * 255.0),
            b: UInt8(0.08 * 255.0),
            a: 255
        )
        let center = pixels[Int(height / 2) * Int(width) + Int(width / 2)]
        #expect(center.distance(from: background) > 64)
        #expect(center.r > 150)
        #expect(center.r > center.b)

        let coveredPixels = pixels.count { $0.distance(from: background) > 48 }
        #expect(coveredPixels > Int(width * height) / 32)
    }

    @Test("particle GPU simulation resources compile and cache",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle simulation smoke test"))
    func particleSimulationResourcesCompileAndCache() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 130,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let resources = try #require(try renderer.ensureParticleSimulationResources(for: plan))
        #expect(resources.capacity >= plan.particleCapacity)
        #expect(resources.workgroupSize == 64)

        let cached = try #require(try renderer.ensureParticleSimulationResources(for: plan))
        #expect(cached.capacity == resources.capacity)
        #expect(cached.workgroupSize == resources.workgroupSize)

        let emitterA = EntityID(index: 11, generation: 1)
        let emitterB = EntityID(index: 12, generation: 1)
        let emitterAResources = try #require(
            try renderer.ensureParticleSimulationResources(for: plan, emitterEntity: emitterA)
        )
        let cachedEmitterAResources = try #require(
            try renderer.ensureParticleSimulationResources(for: plan, emitterEntity: emitterA)
        )
        let emitterBResources = try #require(
            try renderer.ensureParticleSimulationResources(for: plan, emitterEntity: emitterB)
        )
        #expect(renderer.particleSimulationResourcesByEmitter.count == 2)
        #expect(cachedEmitterAResources.capacity == emitterAResources.capacity)
        #expect(cachedEmitterAResources.workgroupSize == emitterAResources.workgroupSize)
        #expect(emitterBResources.capacity == emitterAResources.capacity)
        #expect(emitterBResources.workgroupSize == emitterAResources.workgroupSize)

        let largerWorkgroupPlan = ParticleEmitter(
            maxParticles: 130,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 128
        ).gpuSimulationPlan
        let largerWorkgroupResources = try #require(
            try renderer.ensureParticleSimulationResources(for: largerWorkgroupPlan)
        )
        #expect(largerWorkgroupResources.workgroupSize == 128)
        #expect(largerWorkgroupResources.capacity >= largerWorkgroupPlan.particleCapacity)
        let resizedEmitterAResources = try #require(
            try renderer.ensureParticleSimulationResources(for: largerWorkgroupPlan, emitterEntity: emitterA)
        )
        #expect(renderer.particleSimulationResourcesByEmitter.count == 2)
        #expect(resizedEmitterAResources.workgroupSize == 128)
        #expect(renderer.particleSimulationResourcesByEmitter[emitterA.rawValue]?.workgroupSize == 128)
        #expect(renderer.particleSimulationResourcesByEmitter[emitterB.rawValue]?.workgroupSize == 64)

        let cpuPlan = ParticleEmitter(simulationBackend: .cpu).gpuSimulationPlan
        #expect(try renderer.ensureParticleSimulationResources(for: cpuPlan) == nil)
    }

    @Test("particle GPU simulation dispatch updates state buffer",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle simulation dispatch test"))
    func particleSimulationDispatchUpdatesStateBuffer() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 4,
            collisionMode: .worldPlane,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let particle = Particle(
            position: SIMD3<Float>(0, 0, 0),
            velocity: SIMD3<Float>(1, 2, 3),
            age: 0,
            lifetime: 10,
            rotation: 0.25,
            angularVelocity: 2,
            size: 1,
            color: SIMD4<Float>(1, 0.5, 0.25, 1),
            generation: 3,
            appearanceIndex: 7
        )
        var collisionTransform = matrix_identity_float4x4
        collisionTransform.columns.3.y = 5
        let encoder = try backend.createCommandEncoder()
        let resources = try #require(
            try renderer.encodeParticleSimulationPass(
                encoder: encoder,
                plan: plan,
                particles: [particle],
                deltaTime: 0.5,
                gravity: SIMD3<Float>(0, -10, 0),
                noiseStrength: 2,
                noiseScale: 1,
                noiseSpeed: 0,
                noiseSeed: 0,
                vectorFieldDirection: SIMD3<Float>(2, 0, 0),
                vectorFieldStrength: 4,
                vectorFieldMode: .uniform,
                forceMode: .radial,
                forceCenter: SIMD3<Float>(-1, 0, 0),
                forceRadius: 0,
                forceStrength: 6,
                forceFalloff: 0,
                collisionMode: .worldPlane,
                collisionPlaneY: 4.5,
                collisionRestitution: 0.5,
                collisionDamping: 0.25,
                collisionWorldTransform: collisionTransform
            )
        )

        let stride = UInt64(MemoryLayout<GPUReadbackParticleSimulationState>.stride)
        let readback = try backend.createBuffer(size: stride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.stateBuffer,
                                   destination: readback,
                                   size: stride)
        let metadataStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationMetadata>.stride)
        let metadataReadback = try backend.createBuffer(size: metadataStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.metadataBuffer,
                                   destination: metadataReadback,
                                   size: metadataStride)
        let eventStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationEvent>.stride)
        let eventReadback = try backend.createBuffer(size: eventStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.eventBuffer,
                                   destination: eventReadback,
                                   size: eventStride)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let states = try readbackParticleSimulationStates(buffer: readback,
                                                          count: 1,
                                                          backend: backend)
        let metadata = try #require(
            try readbackParticleSimulationMetadata(buffer: metadataReadback, backend: backend)
        )
        let state = try #require(states.first)
        let expectedNoise = SIMD3<Float>(
            0,
            Float(sin(2.17)) * 2,
            Float(sin(4.31)) * 2
        )
        let expectedAcceleration = SIMD3<Float>(0, -10, 0)
            + expectedNoise
            + SIMD3<Float>(6, 0, 0)
            + SIMD3<Float>(4, 0, 0)
        let preCollisionVelocity = SIMD3<Float>(1, 2, 3) + expectedAcceleration * 0.5
        let preCollisionPosition = preCollisionVelocity * 0.5
        var expectedVelocity = preCollisionVelocity
        var expectedPosition = preCollisionPosition
        if preCollisionPosition.y + collisionTransform.columns.3.y < 4.5 {
            expectedPosition.y = 4.5 - collisionTransform.columns.3.y
            if preCollisionVelocity.y < 0 {
                expectedVelocity.x *= 0.75
                expectedVelocity.y = -preCollisionVelocity.y * 0.5
                expectedVelocity.z *= 0.75
            }
        }
        #expect(abs(state.velocityAge.x - expectedVelocity.x) < 0.001)
        #expect(abs(state.velocityAge.y - expectedVelocity.y) < 0.001)
        #expect(abs(state.velocityAge.z - expectedVelocity.z) < 0.001)
        #expect(abs(state.velocityAge.w - 0.5) < 0.001)
        #expect(abs(state.positionLifetime.x - expectedPosition.x) < 0.001)
        #expect(abs(state.positionLifetime.y - expectedPosition.y) < 0.001)
        #expect(abs(state.positionLifetime.z - expectedPosition.z) < 0.001)
        #expect(abs(state.positionLifetime.w - 10) < 0.001)
        #expect(abs(state.sizeRotation.y - 1.25) < 0.001)
        #expect(abs(state.sizeRotation.z - 2) < 0.001)
        #expect(state.params.x == 3)
        #expect(state.params.y == 7)
        #expect(metadata.aliveCount == 1)
        #expect(metadata.expiredCount == 0)
        #expect(metadata.collisionCount == 1)
        #expect(metadata.spawnedCount == 0)
        #expect(metadata.droppedSpawnCount == 0)
        #expect(metadata.appendCursor == 1)
        #expect(metadata.compactedCount == 1)
        #expect(metadata.eventCount == 1)

        let events = try readbackParticleSimulationEvents(buffer: eventReadback,
                                                          count: 1,
                                                          backend: backend)
        let event = try #require(events.first)
        #expect(event.params.x == 1)
        #expect(event.params.y == 0)
        #expect(event.params.z == 3)
        #expect(event.params.w == 7)
        #expect(abs(event.positionLifetime.x - expectedPosition.x) < 0.001)
        #expect(abs(event.positionLifetime.y - expectedPosition.y) < 0.001)
        #expect(abs(event.positionLifetime.z - expectedPosition.z) < 0.001)
        #expect(abs(event.positionLifetime.w - 10) < 0.001)
        #expect(abs(event.velocityAge.x - expectedVelocity.x) < 0.001)
        #expect(abs(event.velocityAge.y - expectedVelocity.y) < 0.001)
        #expect(abs(event.velocityAge.z - expectedVelocity.z) < 0.001)
        #expect(abs(event.velocityAge.w) < 0.001)
    }

    @Test("particle GPU spawn append writes new state and reports capacity drops",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle spawn append test"))
    func particleSimulationSpawnAppendWritesNewStateAndDropsOverflow() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 2,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let existing = Particle(
            position: SIMD3<Float>(0, 0, 0),
            velocity: .zero,
            age: 0,
            lifetime: 10,
            size: 1,
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        let acceptedSpawn = Particle(
            position: SIMD3<Float>(1, 2, 3),
            velocity: SIMD3<Float>(4, 5, 6),
            age: 0.25,
            lifetime: 9,
            rotation: 0.75,
            angularVelocity: 1.5,
            size: 0.5,
            color: SIMD4<Float>(0.2, 0.4, 0.6, 0.8),
            generation: 2,
            appearanceIndex: 5
        )
        let droppedSpawn = Particle(
            position: SIMD3<Float>(9, 9, 9),
            velocity: .zero,
            age: 0,
            lifetime: 3,
            size: 2,
            color: SIMD4<Float>(1, 0, 0, 1)
        )

        let encoder = try backend.createCommandEncoder()
        let resources = try #require(
            try renderer.encodeParticleSimulationPass(
                encoder: encoder,
                plan: plan,
                particles: [existing],
                deltaTime: 0,
                gravity: .zero,
                spawnParticles: [acceptedSpawn, droppedSpawn]
            )
        )

        let stateStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationState>.stride)
        let stateReadback = try backend.createBuffer(size: stateStride * 2, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.stateBuffer,
                                   destination: stateReadback,
                                   size: stateStride * 2)
        let metadataStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationMetadata>.stride)
        let metadataReadback = try backend.createBuffer(size: metadataStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.metadataBuffer,
                                   destination: metadataReadback,
                                   size: metadataStride)
        let eventStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationEvent>.stride)
        let eventReadback = try backend.createBuffer(size: eventStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.eventBuffer,
                                   destination: eventReadback,
                                   size: eventStride)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let states = try readbackParticleSimulationStates(buffer: stateReadback,
                                                          count: 2,
                                                          backend: backend)
        let metadata = try #require(
            try readbackParticleSimulationMetadata(buffer: metadataReadback, backend: backend)
        )
        #expect(states.count == 2)
        #expect(abs(states[0].positionLifetime.x) < 0.001)
        #expect(abs(states[0].positionLifetime.w - 10) < 0.001)
        #expect(abs(states[1].positionLifetime.x - acceptedSpawn.position.x) < 0.001)
        #expect(abs(states[1].positionLifetime.y - acceptedSpawn.position.y) < 0.001)
        #expect(abs(states[1].positionLifetime.z - acceptedSpawn.position.z) < 0.001)
        #expect(abs(states[1].positionLifetime.w - acceptedSpawn.lifetime) < 0.001)
        #expect(abs(states[1].velocityAge.x - acceptedSpawn.velocity.x) < 0.001)
        #expect(abs(states[1].velocityAge.y - acceptedSpawn.velocity.y) < 0.001)
        #expect(abs(states[1].velocityAge.z - acceptedSpawn.velocity.z) < 0.001)
        #expect(abs(states[1].velocityAge.w - acceptedSpawn.age) < 0.001)
        #expect(abs(states[1].sizeRotation.x - acceptedSpawn.size) < 0.001)
        #expect(abs(states[1].sizeRotation.y - acceptedSpawn.rotation) < 0.001)
        #expect(abs(states[1].sizeRotation.z - acceptedSpawn.angularVelocity) < 0.001)
        #expect(states[1].params.x == 2)
        #expect(states[1].params.y == 5)
        #expect(metadata.aliveCount == 2)
        #expect(metadata.expiredCount == 0)
        #expect(metadata.collisionCount == 0)
        #expect(metadata.spawnedCount == 1)
        #expect(metadata.droppedSpawnCount == 1)
        #expect(metadata.appendCursor == 2)
        #expect(metadata.compactedCount == 2)
    }

    @Test("particle GPU simulation compacts live state and clears the dead tail",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle compaction test"))
    func particleSimulationCompactsLiveStateAndClearsDeadTail() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 4,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let aliveA = Particle(
            position: SIMD3<Float>(1, 0, 0),
            velocity: SIMD3<Float>(0, 1, 0),
            age: 0.1,
            lifetime: 4,
            size: 0.5,
            color: SIMD4<Float>(1, 0, 0, 1)
        )
        let expired = Particle(
            position: SIMD3<Float>(9, 9, 9),
            velocity: SIMD3<Float>(2, 2, 2),
            age: 2,
            lifetime: 1,
            size: 3,
            color: SIMD4<Float>(0, 1, 0, 1),
            generation: 4,
            appearanceIndex: 9
        )
        let aliveB = Particle(
            position: SIMD3<Float>(3, 0, 0),
            velocity: SIMD3<Float>(0, 0, 1),
            age: 0.25,
            lifetime: 8,
            size: 0.75,
            color: SIMD4<Float>(0, 0, 1, 1),
            generation: 6,
            appearanceIndex: 11
        )

        let encoder = try backend.createCommandEncoder()
        let resources = try #require(
            try renderer.encodeParticleSimulationPass(
                encoder: encoder,
                plan: plan,
                particles: [aliveA, expired, aliveB],
                deltaTime: 0,
                gravity: .zero
            )
        )

        let stateStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationState>.stride)
        let stateReadback = try backend.createBuffer(size: stateStride * 4, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.stateBuffer,
                                   destination: stateReadback,
                                   size: stateStride * 4)
        let metadataStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationMetadata>.stride)
        let metadataReadback = try backend.createBuffer(size: metadataStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.metadataBuffer,
                                   destination: metadataReadback,
                                   size: metadataStride)
        let eventStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationEvent>.stride)
        let eventReadback = try backend.createBuffer(size: eventStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.eventBuffer,
                                   destination: eventReadback,
                                   size: eventStride)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let states = try readbackParticleSimulationStates(buffer: stateReadback,
                                                          count: 4,
                                                          backend: backend)
        let metadata = try #require(
            try readbackParticleSimulationMetadata(buffer: metadataReadback, backend: backend)
        )

        #expect(states.count == 4)
        #expect(abs(states[0].positionLifetime.x - aliveA.position.x) < 0.001)
        #expect(abs(states[0].positionLifetime.w - aliveA.lifetime) < 0.001)
        #expect(abs(states[1].positionLifetime.x - aliveB.position.x) < 0.001)
        #expect(abs(states[1].positionLifetime.w - aliveB.lifetime) < 0.001)
        #expect(states[1].params.x == UInt32(aliveB.generation))
        #expect(states[1].params.y == UInt32(aliveB.appearanceIndex))
        #expect(abs(states[2].positionLifetime.w) < 0.001)
        #expect(abs(states[2].velocityAge.w) < 0.001)
        #expect(abs(states[3].positionLifetime.w) < 0.001)
        #expect(abs(states[3].velocityAge.w) < 0.001)
        #expect(metadata.aliveCount == 2)
        #expect(metadata.expiredCount == 1)
        #expect(metadata.spawnedCount == 0)
        #expect(metadata.droppedSpawnCount == 0)
        #expect(metadata.appendCursor == 2)
        #expect(metadata.compactedCount == 2)
        #expect(metadata.eventCount == 1)

        let events = try readbackParticleSimulationEvents(buffer: eventReadback,
                                                          count: 1,
                                                          backend: backend)
        let event = try #require(events.first)
        #expect(event.params.x == 2)
        #expect(event.params.y == 1)
        #expect(event.params.z == 4)
        #expect(event.params.w == 9)
        #expect(abs(event.positionLifetime.x - expired.position.x) < 0.001)
        #expect(abs(event.positionLifetime.y - expired.position.y) < 0.001)
        #expect(abs(event.positionLifetime.z - expired.position.z) < 0.001)
        #expect(abs(event.positionLifetime.w - expired.lifetime) < 0.001)
        #expect(abs(event.velocityAge.x - expired.velocity.x) < 0.001)
        #expect(abs(event.velocityAge.y - expired.velocity.y) < 0.001)
        #expect(abs(event.velocityAge.z - expired.velocity.z) < 0.001)
        #expect(abs(event.velocityAge.w - expired.age) < 0.001)
    }

    @Test("particle GPU simulation reuses compacted emitter state across frames",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle persistence test"))
    func particleSimulationReusesCompactedEmitterStateAcrossFrames() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 4,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let emitter = EntityID(index: 77, generation: 1)
        let staleCPUState = Particle(
            position: SIMD3<Float>(0, 0, 0),
            velocity: SIMD3<Float>(1, 0, 0),
            age: 0,
            lifetime: 10,
            size: 1,
            color: SIMD4<Float>(1, 1, 1, 1)
        )

        do {
            let encoder = try backend.createCommandEncoder()
            _ = try #require(
                try renderer.encodeParticleSimulationPass(
                    encoder: encoder,
                    plan: plan,
                    particles: [staleCPUState],
                    deltaTime: 1,
                    gravity: .zero,
                    emitterEntity: emitter
                )
            )
            let commandBuffer = try encoder.finish()
            backend.submit(commandBuffer)
        }

        let encoder = try backend.createCommandEncoder()
        let resources = try #require(
            try renderer.encodeParticleSimulationPass(
                encoder: encoder,
                plan: plan,
                particles: [staleCPUState],
                deltaTime: 1,
                gravity: .zero,
                emitterEntity: emitter
            )
        )
        let stateStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationState>.stride)
        let stateReadback = try backend.createBuffer(size: stateStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.stateBuffer,
                                   destination: stateReadback,
                                   size: stateStride)
        let metadataStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationMetadata>.stride)
        let metadataReadback = try backend.createBuffer(size: metadataStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.metadataBuffer,
                                   destination: metadataReadback,
                                   size: metadataStride)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let states = try readbackParticleSimulationStates(buffer: stateReadback,
                                                          count: 1,
                                                          backend: backend)
        let metadata = try #require(
            try readbackParticleSimulationMetadata(buffer: metadataReadback, backend: backend)
        )
        let state = try #require(states.first)
        #expect(abs(state.positionLifetime.x - 2) < 0.001)
        #expect(abs(state.velocityAge.w - 2) < 0.001)
        #expect(metadata.aliveCount == 1)
        #expect(metadata.expiredCount == 0)
        #expect(metadata.appendCursor == 1)
        #expect(metadata.compactedCount == 1)
        #expect(renderer.initializedParticleSimulationEmitterKeys.contains(emitter.rawValue))
    }

    @Test("particle GPU simulation preserves append cursor when CPU state is omitted",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle append cursor test"))
    func particleSimulationPreservesAppendCursorWithoutCPUStateUpload() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 4,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let emitter = EntityID(index: 78, generation: 1)
        let resident = Particle(
            position: SIMD3<Float>(1, 0, 0),
            velocity: .zero,
            age: 0,
            lifetime: 10,
            size: 1,
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        let spawned = Particle(
            position: SIMD3<Float>(2, 0, 0),
            velocity: .zero,
            age: 0,
            lifetime: 10,
            size: 1,
            color: SIMD4<Float>(0, 1, 1, 1)
        )

        do {
            let encoder = try backend.createCommandEncoder()
            _ = try #require(
                try renderer.encodeParticleSimulationPass(
                    encoder: encoder,
                    plan: plan,
                    particles: [resident],
                    deltaTime: 0,
                    gravity: .zero,
                    emitterEntity: emitter
                )
            )
            let commandBuffer = try encoder.finish()
            backend.submit(commandBuffer)
        }

        let encoder = try backend.createCommandEncoder()
        let resources = try #require(
            try renderer.encodeParticleSimulationPass(
                encoder: encoder,
                plan: plan,
                particles: [],
                deltaTime: 0,
                gravity: .zero,
                spawnParticles: [spawned],
                emitterEntity: emitter
            )
        )
        let stateStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationState>.stride)
        let stateReadback = try backend.createBuffer(size: stateStride * 2, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.stateBuffer,
                                   destination: stateReadback,
                                   size: stateStride * 2)
        let metadataStride = UInt64(MemoryLayout<GPUReadbackParticleSimulationMetadata>.stride)
        let metadataReadback = try backend.createBuffer(size: metadataStride, usage: [.copyDst, .mapRead])
        encoder.copyBufferToBuffer(source: resources.metadataBuffer,
                                   destination: metadataReadback,
                                   size: metadataStride)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let states = try readbackParticleSimulationStates(buffer: stateReadback,
                                                          count: 2,
                                                          backend: backend)
        let metadata = try #require(
            try readbackParticleSimulationMetadata(buffer: metadataReadback, backend: backend)
        )

        #expect(abs(states[0].positionLifetime.x - resident.position.x) < 0.001)
        #expect(abs(states[0].positionLifetime.w - resident.lifetime) < 0.001)
        #expect(abs(states[1].positionLifetime.x - spawned.position.x) < 0.001)
        #expect(abs(states[1].positionLifetime.w - spawned.lifetime) < 0.001)
        #expect(metadata.aliveCount == 2)
        #expect(metadata.expiredCount == 0)
        #expect(metadata.spawnedCount == 1)
        #expect(metadata.droppedSpawnCount == 0)
        #expect(metadata.appendCursor == 2)
        #expect(metadata.compactedCount == 2)
    }

    @Test("particle GPU render path expands simulation particles into trail instances",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle trail test"))
    func particleSimulationRenderPathExpandsTrailsOnGPU() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 4,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let particle = Particle(
            position: SIMD3<Float>(0, 0, 0),
            velocity: SIMD3<Float>(2, 0, 0),
            age: 0,
            lifetime: 10,
            size: 2,
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        let scene = RenderScene(
            camera: .fallbackPerspective,
            particleSimulationBatches: [
                RenderParticleSimulationBatch(
                    emitterEntity: EntityID(index: 79, generation: 1),
                    plan: plan,
                    particles: [particle],
                    gravity: .zero,
                    renderOnGPU: true,
                    renderAlphaScale: 0.25,
                    trailLength: 1,
                    trailSegments: 2,
                    trailEndSizeScale: 0.5,
                    trailEndAlphaScale: 0
                )
            ]
        )

        let encoder = try backend.createCommandEncoder()
        let report = try renderer.encodeParticleSimulationPrePass(
            encoder: encoder,
            scene: scene,
            deltaTime: 0,
            elapsedTime: 0
        )
        #expect(report.renderInstanceCount == 3)
        #expect(report.eventCapacity == 8)
        #expect(report.eventBufferBytes == 8 * MemoryLayout<GPUReadbackParticleSimulationEvent>.stride)
        #expect(renderer.gpuParticleRenderInstanceCount == 3)
        #expect(renderer.gpuParticleRenderBatches.first?.count == 3)

        let sourceBuffer = try #require(renderer.particleStorageBuffer)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let instances = try readbackParticleInstances(buffer: sourceBuffer,
                                                       count: 3,
                                                       backend: backend)
        #expect(abs(instances[0].positionSize.x - 0) < 0.001)
        #expect(abs(instances[1].positionSize.x + 1) < 0.001)
        #expect(abs(instances[2].positionSize.x + 2) < 0.001)
        #expect(abs(instances[0].positionSize.w - 2) < 0.001)
        #expect(abs(instances[1].positionSize.w - 1.5) < 0.001)
        #expect(abs(instances[2].positionSize.w - 1) < 0.001)
        #expect(abs(instances[0].color.w - 0.25) < 0.001)
        #expect(abs(instances[1].color.w - 0.125) < 0.001)
        #expect(abs(instances[2].color.w) < 0.001)
    }

    @Test("particle GPU render path applies render budgets when expanding simulation particles",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle budget test"))
    func particleSimulationRenderPathAppliesRenderBudgetOnGPU() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let plan = ParticleEmitter(
            maxParticles: 4,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        let particles = (0..<4).map { index in
            Particle(
                position: SIMD3<Float>(Float(index), 0, 0),
                velocity: .zero,
                age: 0,
                lifetime: 10,
                size: 1,
                color: SIMD4<Float>(1, 1, 1, 1)
            )
        }
        let scene = RenderScene(
            camera: .fallbackPerspective,
            particleSimulationBatches: [
                RenderParticleSimulationBatch(
                    emitterEntity: EntityID(index: 80, generation: 1),
                    plan: plan,
                    particles: particles,
                    gravity: .zero,
                    renderOnGPU: true,
                    renderParticleLimit: 2
                )
            ]
        )

        let encoder = try backend.createCommandEncoder()
        let report = try renderer.encodeParticleSimulationPrePass(
            encoder: encoder,
            scene: scene,
            deltaTime: 0,
            elapsedTime: 0
        )
        #expect(report.particleCount == 4)
        #expect(report.renderInstanceCount == 2)
        #expect(report.eventCapacity == 8)
        #expect(report.eventBufferBytes == 8 * MemoryLayout<GPUReadbackParticleSimulationEvent>.stride)
        #expect(renderer.gpuParticleRenderInstanceCount == 2)
        #expect(renderer.gpuParticleRenderBatches.first?.count == 2)

        let sourceBuffer = try #require(renderer.particleStorageBuffer)
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        let instances = try readbackParticleInstances(buffer: sourceBuffer,
                                                       count: 2,
                                                       backend: backend)
        #expect(abs(instances[0].positionSize.x - 2) < 0.001)
        #expect(abs(instances[1].positionSize.x - 3) < 0.001)
    }

    @Test("particle GPU cull compacts batches larger than one workgroup tile",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle cull tiling test"))
    func particleCullCompactsLargeBatchesAcrossWorkgroupTiles() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        var particles: [RenderParticle] = []
        particles.reserveCapacity(130)
        for index in 0..<130 {
            let column = Float((index % 13) - 6)
            let row = Float((index / 13) - 5)
            let position = SIMD3<Float>(column * 0.025, row * 0.025, 0)
            let color = SIMD4<Float>(1, 0.65, 0.2, 1)
            particles.append(RenderParticle(position: position,
                                            size: 0.08,
                                            color: color))
        }
        let scene = RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(0, 0, 3),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 20
            ),
            particles: particles
        )
        let packet = RenderPacket(
            frameIndex: 13,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: 64, height: 64),
            scene: scene,
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 0
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.gpuParticleIndirectDrawCount == 1)
        #expect(stats.gpuParticleCullBatchCount == 1)
        #expect(stats.gpuParticleCullCandidateCount == particles.count)
        #expect(stats.gpuParticleCullDispatchWorkgroups == 1)
        #expect(stats.passDrawCallCounts[.particles] == 1)

        let indirectBuffer = try #require(renderer.particleIndirectDrawBuffer)
        let args = try readbackParticleIndirectDrawArgs(buffer: indirectBuffer,
                                                        count: 1,
                                                        backend: backend)
        #expect(args.first?.vertexCount == 6)
        #expect(args.first?.instanceCount == UInt32(particles.count))
        #expect(args.first?.firstVertex == 0)
        #expect(args.first?.firstInstance == 0)
    }

    @Test("particle GPU simulation prepass is reported during full render",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU particle simulation render test"))
    func particleSimulationPrepassIsReportedDuringFullRender() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        let packet = RenderPacket(
            frameIndex: 12,
            deltaTime: 0.5,
            drawableSize: RenderDrawableSize(width: width, height: height),
            scene: Self.makeParticleSimulationScene(),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 1.25
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.gpuParticleSimulationBatchCount == 2)
        #expect(stats.gpuParticleSimulationParticleCount == 5)
        #expect(stats.gpuParticleSimulationDispatchWorkgroups == 2)
        #expect(stats.gpuParticleSimulationEventCapacity == 12)
        #expect(stats.gpuParticleSimulationEventBufferBytes == 12 * MemoryLayout<GPUReadbackParticleSimulationEvent>.stride)
        #expect(stats.gpuParticleRenderInstanceCount == 5)
        #expect(stats.gpuParticleIndirectDrawCount == 3)
        #expect(stats.gpuParticleCullBatchCount == 3)
        #expect(stats.gpuParticleCullCandidateCount == 6)
        #expect(stats.gpuParticleCullDispatchWorkgroups == 3)
        #expect(stats.gpuParticleSimulationEncodeNS > 0)
        #expect(stats.passDrawCallCounts[.particles] == 3)

        let eventSnapshots = try renderer.drainGPUParticleSimulationEventSnapshots()
        #expect(eventSnapshots.count == 2)
        let firstSnapshot = try #require(eventSnapshots.first { $0.slot == 0 })
        #expect(firstSnapshot.eventCapacity == 6)
        #expect(firstSnapshot.totalEventCount == 1)
        #expect(firstSnapshot.droppedEventCount == 0)
        let deathEvent = try #require(firstSnapshot.records.first)
        #expect(deathEvent.trigger == .death)
        #expect(deathEvent.sourceIndex == 2)
        #expect(deathEvent.generation == 2)
        #expect(deathEvent.appearanceIndex == 4)
        #expect(abs(deathEvent.position.x - 0.25) < 0.001)
        #expect(abs(deathEvent.position.y) < 0.001)
        #expect(abs(deathEvent.position.z) < 0.001)
        #expect(abs(deathEvent.lifetime - 0.5) < 0.001)
        #expect(abs(deathEvent.velocity.x) < 0.001)
        #expect(abs(deathEvent.velocity.y) < 0.001)
        #expect(abs(deathEvent.velocity.z) < 0.001)
        #expect(abs(deathEvent.age - 0.5) < 0.001)
        let secondSnapshot = try #require(eventSnapshots.first { $0.slot == 1 })
        #expect(secondSnapshot.eventCapacity == 6)
        #expect(secondSnapshot.totalEventCount == 0)
        #expect(secondSnapshot.records.isEmpty)
        #expect(try renderer.drainGPUParticleSimulationEventSnapshots().isEmpty)

        guard let indirectBuffer = renderer.particleIndirectDrawBuffer else {
            Issue.record("expected particle indirect draw buffer")
            return
        }
        let args = try readbackParticleIndirectDrawArgs(buffer: indirectBuffer,
                                                        count: 3,
                                                        backend: backend)
        #expect(args.map(\.vertexCount) == [6, 6, 6])
        #expect(args.map(\.instanceCount) == [1, 2, 1])
        #expect(args.map(\.firstVertex) == [0, 0, 0])
        #expect(args.map(\.firstInstance) == [0, 3, 5])

        guard let visibleBuffer = renderer.particleVisibleStorageBuffer else {
            Issue.record("expected particle visible storage buffer")
            return
        }
        let visibleInstances = try readbackParticleInstances(buffer: visibleBuffer,
                                                             count: 5,
                                                             backend: backend)
        #expect(abs(visibleInstances[3].axisStretch.x) < 0.001)
        #expect(abs(visibleInstances[3].axisStretch.y - 1) < 0.001)
        #expect(abs(visibleInstances[3].axisStretch.z) < 0.001)
        #expect(abs(visibleInstances[3].axisStretch.w - 1.5) < 0.001)
        #expect(abs(visibleInstances[4].axisStretch.x) < 0.001)
        #expect(abs(visibleInstances[4].axisStretch.y - 1) < 0.001)
        #expect(abs(visibleInstances[4].axisStretch.z) < 0.001)
        #expect(abs(visibleInstances[4].axisStretch.w - 1.25) < 0.001)
    }

    @Test("opaque-cache overlay frame matches a full render and camera change invalidates it",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU opaque-cache smoke test"))
    func opaqueCacheOverlayMatchesFullRender() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }
        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }
        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        // r5 HDR path with bloom, TAA off → opaque cache is eligible.
        let settings = RenderSettings(stage: .r5PostProcess,
                                      enableBloom: true,
                                      enableOffscreenViewport: true)
        func packet(eye: SIMD3<Float>) -> RenderPacket {
            RenderPacket(
                frameIndex: 0,
                deltaTime: 1.0 / 60.0,
                drawableSize: RenderDrawableSize(width: width, height: height),
                scene: Self.makeOpaqueCacheScene(cameraEye: eye),
                sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
                renderSettings: settings,
                simulationTimeSeconds: 0
            )
        }

        // Frame 0: cache miss → full render, populates the opaque snapshot.
        renderer.render(packet: packet(eye: SIMD3<Float>(0, 0, 3.2)))
        #expect(renderer.lastFrameUsedOpaqueCache == false)
        guard let tex0 = renderer.offscreenColorTexture else {
            Issue.record("expected offscreen color texture")
            return
        }
        let full = try readbackBGRA8(texture: tex0, width: width, height: height, backend: backend)

        // Frame 1: identical inputs → cache hit, opaque passes skipped.
        renderer.render(packet: packet(eye: SIMD3<Float>(0, 0, 3.2)))
        #expect(renderer.lastFrameUsedOpaqueCache == true)
        guard let tex1 = renderer.offscreenColorTexture else {
            Issue.record("expected offscreen color texture")
            return
        }
        let cached = try readbackBGRA8(texture: tex1, width: width, height: height, backend: backend)

        // The overlay path must reproduce the full render (allow tiny rounding).
        #expect(full.count == cached.count)
        var maxDiff = 0
        for i in full.indices where i < cached.count {
            maxDiff = max(maxDiff, full[i].distance(from: cached[i]))
        }
        #expect(maxDiff <= 2)

        // Moving the camera changes the opaque inputs → cache must invalidate.
        renderer.render(packet: packet(eye: SIMD3<Float>(1.6, 0.5, 3.0)))
        #expect(renderer.lastFrameUsedOpaqueCache == false)
    }

    @Test("opaque cache engages under TAA only after temporal convergence",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU TAA opaque-cache smoke test"))
    func opaqueCacheConvergesUnderTAA() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }
        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }
        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        // TAA on: the cache must wait for temporal convergence before trusting
        // the snapshot.
        let settings = RenderSettings(stage: .r5PostProcess,
                                      enableTAA: true,
                                      enableBloom: true,
                                      enableOffscreenViewport: true)
        func packet(eye: SIMD3<Float>, frame: Int) -> RenderPacket {
            RenderPacket(
                frameIndex: frame,
                deltaTime: 1.0 / 60.0,
                drawableSize: RenderDrawableSize(width: width, height: height),
                scene: Self.makeOpaqueCacheScene(cameraEye: eye),
                sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
                renderSettings: settings,
                simulationTimeSeconds: 0
            )
        }

        let warmup = WGPURenderer.taaCacheWarmupFrames
        var converged: [BGRAPixel] = []
        // During warmup the cache must NOT engage — TAA history is still settling.
        for frame in 0...warmup {
            renderer.render(packet: packet(eye: SIMD3<Float>(0, 0, 3.2), frame: frame))
            #expect(renderer.lastFrameUsedOpaqueCache == false)
            guard let tex = renderer.offscreenColorTexture else {
                Issue.record("expected offscreen color texture")
                return
            }
            converged = try readbackBGRA8(texture: tex, width: width, height: height, backend: backend)
        }

        // Next steady frame: TAA has converged → cache engages.
        renderer.render(packet: packet(eye: SIMD3<Float>(0, 0, 3.2), frame: warmup + 1))
        #expect(renderer.lastFrameUsedOpaqueCache == true)
        guard let texHit = renderer.offscreenColorTexture else {
            Issue.record("expected offscreen color texture")
            return
        }
        let cached = try readbackBGRA8(texture: texHit, width: width, height: height, backend: backend)

        // The cached overlay reproduces the converged full render.
        #expect(converged.count == cached.count)
        var maxDiff = 0
        for i in converged.indices where i < cached.count {
            maxDiff = max(maxDiff, converged[i].distance(from: cached[i]))
        }
        #expect(maxDiff <= 2)

        // Moving the camera invalidates the cache → must re-converge.
        renderer.render(packet: packet(eye: SIMD3<Float>(1.6, 0.5, 3.0), frame: warmup + 2))
        #expect(renderer.lastFrameUsedOpaqueCache == false)
    }

    @Test("stylized outline pass compiles and renders through the HDR viewport path",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU stylized outline smoke test"))
    func stylizedOutlinePassCompilesAndRenders() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        let pixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: Self.makeSmokeScene(),
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true,
                enableStylizedCharacterShading: true
            ),
            frameIndex: 2,
            width: width,
            height: height
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.depthPrepass))
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.outline))
        #expect(stats.activePasses.contains(.inkPaperPost))
        #expect(stats.activePasses.contains(.viewportResolve))
        #expect(stats.passDrawCallCounts[.depthPrepass] == 1)
        #expect(stats.passDrawCallCounts[.basePass] == 1)
        #expect(stats.passDrawCallCounts[.outline] == 1)

        let nonTransparentPixels = pixels.count { $0.a > 0 }
        #expect(nonTransparentPixels == Int(width * height))
    }

    @Test("directional shadow pass darkens occluded framebuffer pixels",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU shadow smoke test"))
    func directionalShadowPassDarkensOccludedPixels() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 96
        let height: UInt32 = 96
        let scene = Self.makeShadowScene()
        let noShadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true
            ),
            frameIndex: 0,
            width: width,
            height: height
        )
        let shadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: true,
                enableOffscreenViewport: true
            ),
            frameIndex: 1,
            width: width,
            height: height
        )
        try writeDebugPPMIfRequested(
            pixels: shadowPixels,
            width: width,
            height: height,
            environmentKey: "GUAVA_GPU_SHADOW_OUTPUT"
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.depthPrepass))
        #expect(stats.activePasses.contains(.shadowPass))
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.tonemap))
        #expect(stats.passEncodeNS.keys.contains(.depthPrepass))
        #expect(stats.passEncodeNS.keys.contains(.shadowPass))
        #expect(stats.passDrawCallCounts[.depthPrepass] == 2)
        #expect(stats.passDrawCallCounts[.shadowPass] == 2)
        #expect(stats.passDrawCallCounts[.basePass] == 2)
        #expect(stats.shadowedLightCount == 1)
        #expect(stats.shadowMapResolution == RenderShadowSettings.directionalPreview.mapResolution)

        let darkerPixels = zip(noShadowPixels, shadowPixels).filter { before, after in
            after.luminance + 10 < before.luminance
        }.count
        let noShadowAverage = averageLuminance(noShadowPixels)
        let shadowAverage = averageLuminance(shadowPixels)

        #expect(darkerPixels > Int(width * height) / 64)
        #expect(shadowAverage + 1.0 < noShadowAverage)
    }

    @Test("multi directional shadow atlas encodes one tile per selected light",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU shadow atlas smoke test"))
    func multiDirectionalShadowAtlasEncodesOneTilePerLight() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        var scene = Self.makeShadowScene()
        scene.lights.append(
            RenderLight(
                type: .directional,
                direction: SIMD3<Float>(-0.60, -1.0, 0.42),
                color: SIMD3<Float>(0.78, 0.84, 1.0),
                intensity: 1.4
            )
        )

        let width: UInt32 = 96
        let height: UInt32 = 96
        let noShadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true
            ),
            frameIndex: 10,
            width: width,
            height: height
        )
        let shadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                shadowSettings: RenderShadowSettings(
                    enabled: true,
                    maxShadowedDirectionalLights: 2
                ),
                enableOffscreenViewport: true
            ),
            frameIndex: 11,
            width: width,
            height: height
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.shadowedLightCount == 2)
        #expect(stats.shadowMapResolution == RenderShadowSettings.directionalPreview.mapResolution)
        #expect(stats.passDrawCallCounts[.shadowPass] == scene.instances.count * 2)
        #expect(stats.passDrawCallCounts[.basePass] == scene.instances.count)

        let darkerPixels = zip(noShadowPixels, shadowPixels).filter { before, after in
            after.luminance + 8 < before.luminance
        }.count
        #expect(darkerPixels > Int(width * height) / 80)
    }

    @Test("directional cascades encode one atlas tile per cascade",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU cascaded shadow smoke test"))
    func directionalCascadesEncodeOneAtlasTilePerCascade() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let scene = Self.makeShadowScene()
        let width: UInt32 = 96
        let height: UInt32 = 96
        let noShadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true
            ),
            frameIndex: 20,
            width: width,
            height: height
        )
        let shadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                shadowSettings: RenderShadowSettings(
                    enabled: true,
                    maxShadowedDirectionalLights: 1,
                    directionalCascadeCount: 3
                ),
                enableOffscreenViewport: true
            ),
            frameIndex: 21,
            width: width,
            height: height
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.shadowedLightCount == 1)
        #expect(stats.shadowTileCount == 3)
        #expect(stats.shadowCascadeCount == 3)
        #expect(stats.shadowMapResolution == RenderShadowSettings.directionalPreview.mapResolution)
        #expect(stats.shadowAtlasResolution == RenderShadowSettings.directionalPreview.mapResolution * 2)
        #expect(stats.passDrawCallCounts[.shadowPass] == scene.instances.count * 3)

        let darkerPixels = zip(noShadowPixels, shadowPixels).filter { before, after in
            after.luminance + 8 < before.luminance
        }.count
        #expect(darkerPixels > Int(width * height) / 80)
    }

    @Test("skinned mesh with non-empty joint palette does not crash the GPU pipeline",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the skinned mesh GPU smoke test"))
    func skinnedMeshPaletteDoesNotCrashGPUPipeline() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64

        let skinnedEntity = EntityID(index: 1, generation: 1)
        var palette = JointPaletteMap()
        palette.palettes[skinnedEntity] = JointPalette(matrices: [matrix_identity_float4x4])

        let packet = RenderPacket(
            frameIndex: 0,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: width, height: height),
            scene: Self.makeSmokeScene(),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 0,
            jointPaletteMap: palette
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.viewportResolve))

        let viewport = renderer.currentViewportSurfaceState()
        #expect(viewport.isValid)
        #expect(viewport.width == width)
        #expect(viewport.height == height)
    }

    private static func makeSmokeScene() -> RenderScene {
        RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(0, 0, 3.2),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 20
            ),
            instances: [
                RenderInstance(
                    meshIndex: 0,
                    transform: matrix_identity_float4x4,
                    colorTint: SIMD3<Float>(1.0, 0.72, 0.55),
                    material: RenderMaterial(
                        baseColorFactor: SIMD4<Float>(1.0, 0.82, 0.72, 1.0),
                        roughnessFactor: 0.65
                    )
                )
            ],
            lights: [
                RenderLight(
                    type: .directional,
                    direction: SIMD3<Float>(0, 0, -1),
                    color: SIMD3<Float>(1.0, 0.96, 0.90),
                    intensity: 1.25
                )
            ],
            environment: RenderEnvironment(
                ambientColor: SIMD3<Float>(0.12, 0.14, 0.18),
                ambientIntensity: 0.18,
                exposure: 1
            )
        )
    }

    private static func makeParticleScene() -> RenderScene {
        RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(0, 0, 3.2),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 20
            ),
            particles: [
                RenderParticle(
                    position: .zero,
                    size: 1.2,
                    color: SIMD4<Float>(1.0, 0.5, 0.1, 1.0)
                ),
                RenderParticle(
                    position: SIMD3<Float>(0.25, 0.1, 0),
                    size: 0.9,
                    color: SIMD4<Float>(0.2, 0.55, 1.0, 0.8),
                    blendMode: .additive
                )
            ]
        )
    }

    private static func makeParticleSimulationScene() -> RenderScene {
        let plan = ParticleEmitter(
            maxParticles: 3,
            simulationBackend: .gpuIfSupported,
            gpuSimulationWorkgroupSize: 64
        ).gpuSimulationPlan
        return RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(0, 0, 3.2),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 20
            ),
            particles: [
                RenderParticle(position: SIMD3<Float>(-0.35, 0.2, 0),
                               size: 0.35,
                               color: SIMD4<Float>(1, 0.5, 0, 0.9))
            ],
            particleSimulationBatches: [
                RenderParticleSimulationBatch(
                    plan: plan,
                    particles: [
                        Particle(position: .zero,
                                 velocity: .zero,
                                 age: 0,
                                 lifetime: 10,
                                 size: 1,
                                 color: SIMD4<Float>(1, 1, 1, 1)),
                        Particle(position: SIMD3<Float>(100, 0.1, 0),
                                 velocity: .zero,
                                 age: 0.25,
                                 lifetime: 8,
                                 size: 0.5,
                                 color: SIMD4<Float>(1, 0, 0, 1)),
                        Particle(position: SIMD3<Float>(0.25, 0, 0),
                                 velocity: .zero,
                                 age: 0.4,
                                 lifetime: 0.5,
                                 size: 1,
                                 color: SIMD4<Float>(1, 0, 1, 1),
                                 generation: 2,
                                 appearanceIndex: 4)
                    ],
                    gravity: .zero,
                    renderOnGPU: true,
                    textureSheetColumns: 2,
                    textureSheetRows: 2,
                    textureSheetFrameCount: 4
                ),
                RenderParticleSimulationBatch(
                    plan: plan,
                    particles: [
                        Particle(position: SIMD3<Float>(-0.15, 0, 0),
                                 velocity: SIMD3<Float>(0, 2, 0),
                                 age: 0,
                                 lifetime: 10,
                                 size: 0.75,
                                 color: SIMD4<Float>(0, 1, 0, 1)),
                        Particle(position: SIMD3<Float>(0.35, -0.1, 0),
                                 velocity: SIMD3<Float>(0, 1, 0),
                                 age: 0.1,
                                 lifetime: 8,
                                 size: 0.4,
                                 color: SIMD4<Float>(0, 0.5, 1, 1))
                    ],
                    gravity: .zero,
                    renderOnGPU: true,
                    blendMode: .additive,
                    renderAlignment: .velocity,
                    velocityStretchScale: 0.25,
                    velocityStretchMax: 1.5
                )
            ]
        )
    }

    private static func makeOpaqueCacheScene(cameraEye: SIMD3<Float>) -> RenderScene {
        RenderScene(
            camera: RenderCamera(
                eye: cameraEye,
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 20
            ),
            instances: [
                RenderInstance(
                    meshIndex: 0,
                    transform: matrix_identity_float4x4,
                    colorTint: SIMD3<Float>(0.70, 0.72, 0.80),
                    material: RenderMaterial(baseColorFactor: SIMD4<Float>(0.70, 0.72, 0.80, 1))
                )
            ],
            lights: [
                RenderLight(
                    type: .directional,
                    direction: SIMD3<Float>(0, 0, -1),
                    color: SIMD3<Float>(1, 0.96, 0.9),
                    intensity: 1.2
                )
            ],
            particles: [
                RenderParticle(position: SIMD3<Float>(0, 0.6, 0), size: 0.8,
                               color: SIMD4<Float>(1.0, 0.45, 0.12, 1.0))
            ]
        )
    }

    private static func makeShadowScene() -> RenderScene {
        RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(2.4, 1.6, 3.0),
                target: SIMD3<Float>(0, -0.35, 0),
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 30
            ),
            instances: [
                RenderInstance(
                    meshIndex: 0,
                    transform: translation(SIMD3<Float>(0, -0.65, 0))
                        * scale(SIMD3<Float>(4.5, 0.08, 4.5)),
                    colorTint: SIMD3<Float>(0.96, 0.94, 0.88),
                    material: RenderMaterial(
                        baseColorFactor: SIMD4<Float>(0.96, 0.94, 0.88, 1)
                    )
                ),
                RenderInstance(
                    meshIndex: 0,
                    transform: translation(SIMD3<Float>(-0.15, -0.10, 0.05))
                        * scale(SIMD3<Float>(0.85, 0.85, 0.85)),
                    colorTint: SIMD3<Float>(1.0, 0.45, 0.23),
                    material: RenderMaterial(
                        baseColorFactor: SIMD4<Float>(1.0, 0.45, 0.23, 1)
                    )
                ),
            ],
            lights: [
                RenderLight(
                    type: .directional,
                    direction: SIMD3<Float>(0.45, -1.0, -0.35),
                    color: SIMD3<Float>(1.0, 0.96, 0.88),
                    intensity: 1.8
                )
            ],
            environment: RenderEnvironment(
                ambientColor: SIMD3<Float>(0.20, 0.22, 0.26),
                ambientIntensity: 0.16,
                exposure: 1
            )
        )
    }
}

private struct BGRAPixel: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    func distance(from other: BGRAPixel) -> Int {
        abs(Int(r) - Int(other.r))
            + abs(Int(g) - Int(other.g))
            + abs(Int(b) - Int(other.b))
    }

    var luminance: Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }
}

private struct GPUReadbackParticleSimulationState {
    var positionLifetime: SIMD4<Float>
    var velocityAge: SIMD4<Float>
    var sizeRotation: SIMD4<Float>
    var color: SIMD4<Float>
    var params: SIMD4<UInt32>
}

private struct GPUReadbackParticleSimulationMetadata {
    var aliveCount: UInt32
    var expiredCount: UInt32
    var collisionCount: UInt32
    var spawnedCount: UInt32
    var droppedSpawnCount: UInt32
    var appendCursor: UInt32
    var compactedCount: UInt32
    var eventCount: UInt32
}

private struct GPUReadbackParticleSimulationEvent {
    var positionLifetime: SIMD4<Float>
    var velocityAge: SIMD4<Float>
    var params: SIMD4<UInt32>
}

private struct GPUReadbackParticleIndirectDrawArgs {
    var vertexCount: UInt32
    var instanceCount: UInt32
    var firstVertex: UInt32
    var firstInstance: UInt32
}

private struct GPUReadbackParticleInstance {
    var positionSize: SIMD4<Float>
    var rotation: SIMD4<Float>
    var color: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var axisStretch: SIMD4<Float>
}

private func renderPixels(
    renderer: WGPURenderer,
    backend: WGPUBackend,
    scene: RenderScene,
    settings: RenderSettings,
    frameIndex: Int,
    width: UInt32,
    height: UInt32
) throws -> [BGRAPixel] {
    let packet = RenderPacket(
        frameIndex: frameIndex,
        deltaTime: 1.0 / 60.0,
        drawableSize: RenderDrawableSize(width: width, height: height),
        scene: scene,
        sceneSnapshot: SceneRuntimeSnapshot(entityCount: scene.instances.count, revision: UInt64(frameIndex + 1)),
        renderSettings: settings,
        simulationTimeSeconds: Double(frameIndex) / 60.0
    )
    renderer.render(packet: packet)

    guard let texture = renderer.offscreenColorTexture else {
        Issue.record("expected renderer to retain an offscreen color texture")
        return []
    }
    return try readbackBGRA8(
        texture: texture,
        width: width,
        height: height,
        backend: backend
    )
}

private func readbackBGRA8(
    texture: GPUTexture,
    width: UInt32,
    height: UInt32,
    backend: WGPUBackend
) throws -> [BGRAPixel] {
    let bytesPerPixel: UInt32 = 4
    let unpaddedBytesPerRow = width * bytesPerPixel
    let bytesPerRow = alignedCopyBytesPerRow(unpaddedBytesPerRow)
    let bufferSize = UInt64(bytesPerRow * height)
    let readback = try backend.createBuffer(
        size: bufferSize,
        usage: [.copyDst, .mapRead]
    )

    let encoder = try backend.createCommandEncoder()
    encoder.copyTextureToBuffer(
        source: texture,
        destination: readback,
        bytesPerRow: bytesPerRow,
        rowsPerImage: height,
        width: width,
        height: height
    )
    let commandBuffer = try encoder.finish()
    backend.submit(commandBuffer)

    try backend.bufferMapSync(readback, size: bufferSize)
    defer { readback.unmap() }

    guard let mapped = readback.getMappedRange(size: bufferSize) else {
        Issue.record("readback buffer mapping returned nil")
        return []
    }

    let bytes = UnsafeRawBufferPointer(
        start: mapped,
        count: Int(bufferSize)
    )
    var pixels: [BGRAPixel] = []
    pixels.reserveCapacity(Int(width * height))

    for y in 0..<Int(height) {
        let rowStart = y * Int(bytesPerRow)
        for x in 0..<Int(width) {
            let offset = rowStart + x * Int(bytesPerPixel)
            pixels.append(
                BGRAPixel(
                    r: bytes[offset + 2],
                    g: bytes[offset + 1],
                    b: bytes[offset + 0],
                    a: bytes[offset + 3]
                )
            )
        }
    }

    return pixels
}

private func readbackParticleSimulationStates(
    buffer: GPUBuffer,
    count: Int,
    backend: WGPUBackend
) throws -> [GPUReadbackParticleSimulationState] {
    let stride = MemoryLayout<GPUReadbackParticleSimulationState>.stride
    let bufferSize = UInt64(max(0, count) * stride)
    try backend.bufferMapSync(buffer, size: bufferSize)
    defer { buffer.unmap() }

    guard let mapped = buffer.getMappedRange(size: bufferSize) else {
        Issue.record("particle simulation readback buffer mapping returned nil")
        return []
    }

    let typed = mapped.bindMemory(to: GPUReadbackParticleSimulationState.self,
                                  capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: count))
}

private func readbackParticleSimulationMetadata(
    buffer: GPUBuffer,
    backend: WGPUBackend
) throws -> GPUReadbackParticleSimulationMetadata? {
    let bufferSize = UInt64(MemoryLayout<GPUReadbackParticleSimulationMetadata>.stride)
    try backend.bufferMapSync(buffer, size: bufferSize)
    defer { buffer.unmap() }

    guard let mapped = buffer.getMappedRange(size: bufferSize) else {
        Issue.record("particle simulation metadata readback buffer mapping returned nil")
        return nil
    }

    return mapped.load(as: GPUReadbackParticleSimulationMetadata.self)
}

private func readbackParticleSimulationEvents(
    buffer: GPUBuffer,
    count: Int,
    backend: WGPUBackend
) throws -> [GPUReadbackParticleSimulationEvent] {
    let stride = MemoryLayout<GPUReadbackParticleSimulationEvent>.stride
    let bufferSize = UInt64(max(0, count) * stride)
    try backend.bufferMapSync(buffer, size: bufferSize)
    defer { buffer.unmap() }

    guard let mapped = buffer.getMappedRange(size: bufferSize) else {
        Issue.record("particle simulation event readback buffer mapping returned nil")
        return []
    }

    let typed = mapped.bindMemory(to: GPUReadbackParticleSimulationEvent.self,
                                  capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: count))
}

private func readbackParticleIndirectDrawArgs(
    buffer: GPUBuffer,
    count: Int,
    backend: WGPUBackend
) throws -> [GPUReadbackParticleIndirectDrawArgs] {
    let stride = MemoryLayout<GPUReadbackParticleIndirectDrawArgs>.stride
    let bufferSize = UInt64(max(0, count) * stride)
    let readback = try backend.createBuffer(size: bufferSize, usage: [.copyDst, .mapRead])
    let encoder = try backend.createCommandEncoder()
    encoder.copyBufferToBuffer(source: buffer,
                               destination: readback,
                               size: bufferSize)
    let commandBuffer = try encoder.finish()
    backend.submit(commandBuffer)

    try backend.bufferMapSync(readback, size: bufferSize)
    defer { readback.unmap() }

    guard let mapped = readback.getMappedRange(size: bufferSize) else {
        Issue.record("particle indirect args readback buffer mapping returned nil")
        return []
    }

    let typed = mapped.bindMemory(to: GPUReadbackParticleIndirectDrawArgs.self,
                                  capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: count))
}

private func readbackParticleInstances(
    buffer: GPUBuffer,
    count: Int,
    backend: WGPUBackend
) throws -> [GPUReadbackParticleInstance] {
    let stride = MemoryLayout<GPUReadbackParticleInstance>.stride
    let bufferSize = UInt64(max(0, count) * stride)
    let readback = try backend.createBuffer(size: bufferSize, usage: [.copyDst, .mapRead])
    let encoder = try backend.createCommandEncoder()
    encoder.copyBufferToBuffer(source: buffer,
                               destination: readback,
                               size: bufferSize)
    let commandBuffer = try encoder.finish()
    backend.submit(commandBuffer)

    try backend.bufferMapSync(readback, size: bufferSize)
    defer { readback.unmap() }

    guard let mapped = readback.getMappedRange(size: bufferSize) else {
        Issue.record("particle instance readback buffer mapping returned nil")
        return []
    }

    let typed = mapped.bindMemory(to: GPUReadbackParticleInstance.self,
                                  capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: count))
}

private func alignedCopyBytesPerRow(_ bytesPerRow: UInt32) -> UInt32 {
    let alignment: UInt32 = 256
    return ((bytesPerRow + alignment - 1) / alignment) * alignment
}

private func writeDebugPPMIfRequested(
    pixels: [BGRAPixel],
    width: UInt32,
    height: UInt32,
    environmentKey: String = "GUAVA_GPU_SMOKE_OUTPUT"
) throws {
    guard let output = ProcessInfo.processInfo.environment[environmentKey],
          !output.isEmpty
    else {
        return
    }

    var data = Data("P6\n\(width) \(height)\n255\n".utf8)
    data.reserveCapacity(data.count + pixels.count * 3)
    for pixel in pixels {
        data.append(pixel.r)
        data.append(pixel.g)
        data.append(pixel.b)
    }
    try data.write(to: URL(fileURLWithPath: output))
}

private func averageLuminance(_ pixels: [BGRAPixel]) -> Double {
    guard !pixels.isEmpty else { return 0 }
    return pixels.reduce(0) { $0 + $1.luminance } / Double(pixels.count)
}

private func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, value.x),
        SIMD4<Float>(0, 1, 0, value.y),
        SIMD4<Float>(0, 0, 1, value.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func scale(_ value: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(value.x, 0, 0, 0),
        SIMD4<Float>(0, value.y, 0, 0),
        SIMD4<Float>(0, 0, value.z, 0),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
