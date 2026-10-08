import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import RHIWGPU
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeParticleSimulationTests: XCTestCase {
    func testSimulationLayoutsAndPacketValidation() throws {
        XCTAssertEqual(MemoryLayout<GPUParticleSimulationState>.stride,80)
        XCTAssertEqual(MemoryLayout<GPUParticleSimulationUniforms>.stride,272)
        XCTAssertEqual(MemoryLayout<GPUParticleSimulationMetadata>.stride,32)
        XCTAssertEqual(MemoryLayout<GPUParticleSimulationEvent>.stride,48)
        for api in [GraphicsAPI.metal,.vulkan] {
            let artifact = try NativeShaderLibrary.artifact(name: "particle_simulate",api: api,stage: .compute)
            XCTAssertEqual(artifact.interface.threadgroupSpecialization.x,0)
            XCTAssertEqual(artifact.interface.bindings.first { $0.slot == 1 }?.buffer.elementStride,80)
            XCTAssertEqual(artifact.interface.bindings.first { $0.slot == 2 }?.buffer.elementStride,32)
            XCTAssertEqual(artifact.interface.bindings.first { $0.slot == 3 }?.buffer.elementStride,48)
            XCTAssertEqual(try artifact.moduleDescriptor(specialization: [.init(id: 0,value: .uint32(37))]).threadgroupSize.x,37)
        }
        var packet = MeshProbeScene.packet(size: .init(width: 64,height: 64))
        var batch = makeBatch(group: 37,count: 3)
        batch.emitterEntity = EntityID(rawValue: 19)
        packet.scene.particleSimulationBatches = [batch]
        _ = try NativePacketValidation.validate(packet)
        packet.scene.particleSimulationBatches = [batch,batch]
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
        packet.scene.particleSimulationBatches = [batch]
        packet.scene.particleSimulationBatches[0].forceStrength = .nan
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
        packet.scene.particleSimulationBatches = [batch]
        packet.scene.particleSimulationBatches[0].particles[0].angularVelocity = .infinity
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
        packet.scene.particleSimulationBatches = [batch]
        packet.scene.particleSimulationBatches[0].renderOnGPU = true
        _ = try NativePacketValidation.validate(packet)
        packet.scene.particleSimulationBatches[0].trailSegments = Int.max
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
        packet.scene.particleSimulationBatches = [batch]
        packet.scene.particleSimulationBatches[0].plan.particleCapacity = (1 << 24)+1
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
    }
    #if os(macOS)
    func testMetalPhysicsAndEventsMatchWGPUAcrossWorkgroups() throws { try physics(.metal) }
    func testMetalResidencyResetFailedRecordingAndBoundedSnapshots() throws { try lifecycle(.metal) }
    func testMetalRendererPublishesSimulationEvents() throws { try rendererEvents(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanPhysicsAndEventsMatchWGPUAcrossWorkgroups() throws { try physics(.vulkan) }
    func testVulkanResidencyResetFailedRecordingAndBoundedSnapshots() throws { try lifecycle(.vulkan) }
    func testVulkanRendererPublishesSimulationEvents() throws { try rendererEvents(.vulkan) }
    #endif
    private func makeBatch(group: Int, count: Int) -> RenderParticleSimulationBatch {
        let plan = ParticleEmitter(settings: .init {
            $0.emission.maxParticles = count+3
            $0.gpuSimulation.simulationBackend = .gpuRequired
            $0.gpuSimulation.workgroupSize = group
        }).gpuSimulationPlan
        let particles = (0..<count).map { index in
            Particle(position: SIMD3(Float(index%13)*0.03,Float(index%7)*0.1-0.2,Float(index%11)*0.02),
                velocity: SIMD3(0.2,-1,0.3),age: Float(index%5)*0.1,lifetime: index%17 == 0 ? 0.1 : 8,
                sizeScale: 0.8,rotation: 0.25,angularVelocity: 2,size: 0.4,color: SIMD4(1,0.5,0.25,0.8),
                generation: UInt8(index%7),appearanceIndex: UInt16(index),textureFrameSeed: UInt16(index))
        }
        return RenderParticleSimulationBatch(plan: plan,particles: particles,gravity: SIMD3(0,-2,0),
            noiseStrength: 0.25,noiseScale: 0.8,noiseSpeed: 0.6,noiseSeed: 987654321,
            vectorFieldMode: .uniform,vectorFieldDirection: SIMD3(2,0,0),vectorFieldStrength: 0.3,
            vectorFieldScale: 0.7,vectorFieldScrollSpeed: 0.4,
            forceMode: .radial,forceCenter: SIMD3(-1,0,0),forceAxis: SIMD3(0,1,0),forceRadius: 3,forceStrength: 0.4,forceFalloff: 0.8,
            collisionMode: .localPlane,collisionPlaneY: 0,collisionRestitution: 0.5,collisionDamping: 0.25)
    }
    private func physics(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let simulation = NativeParticleSimulation(device: device)
        let reference = try WGPUSceneReference(validation: true)
        for (scenario,pair) in [(1,257),(37,257),(64,131),(255,257),(256,513)].enumerated() {
            var batch = makeBatch(group: pair.0,count: pair.1)
            if scenario%2 == 1 {
                batch.vectorFieldMode = .curl; batch.forceMode = .vortex; batch.collisionMode = .worldPlane
                var transform = matrix_identity_float4x4
                transform.columns.0 = SIMD4(0.8,0.4,0,0); transform.columns.1 = SIMD4(-0.3,1.1,0,0)
                transform.columns.2.z = 1.3; transform.columns.3 = SIMD4(0.2,0.1,-0.3,1)
                batch.worldTransform = transform; batch.collisionPlaneY = 0.4
            }
            if scenario == 4 { batch.forceRadius = 0; batch.forceAxis = .zero; batch.vectorFieldDirection = .zero }
            let scene = RenderScene(camera: RenderCamera(eye: SIMD3(0,0,5),target: .zero),particleSimulationBatches: [batch])
            try device.beginFrame(); let commands = CommandBuffer()
            let update = try simulation.prepare(scene: scene,deltaTime: 0.2,elapsedTime: 1.7,into: commands)
            try device.submit(commands); simulation.commit(update); device.endFrame()
            let native = try XCTUnwrap(simulation.entries[.anonymous(0)]?.state)
            let encoder = try reference.backend.createCommandEncoder()
            let wgpu = try XCTUnwrap(reference.renderer.encodeParticleSimulationPass(encoder: encoder,batch: batch,deltaTime: 0.2,elapsedTime: 1.7)).resources
            reference.backend.submit(try encoder.finish())
            let rawStates = try nativeStates(device: device,state: native)
            for state in rawStates where state.positionLifetime.w == 0 {
                XCTAssertTrue(withUnsafeBytes(of: state) { $0.allSatisfy { $0 == 0 } })
            }
            let actual = rawStates.filter { $0.positionLifetime.w > 0 }.sorted { $0.params.z < $1.params.z }
            let expected: [GPUParticleSimulationState] = try wgpuRead(reference.backend,buffer: wgpu.stateBuffer,count: wgpu.capacity)
            let live = expected.filter { $0.positionLifetime.w > 0 }.sorted { $0.params.z < $1.params.z }
            XCTAssertEqual(actual.count,live.count)
            for (a,b) in zip(actual,live) {
                XCTAssertEqual(a.params,b.params); compare(a.positionLifetime,b.positionLifetime)
                compare(a.velocityAge,b.velocityAge); compare(a.sizeRotation,b.sizeRotation); compare(a.color,b.color)
            }
            let snapshots = try simulation.drain(maxSnapshots: 1)
            let snapshot = try XCTUnwrap(snapshots.first)
            let counters: [GPUParticleSimulationMetadata] = try wgpuRead(reference.backend,buffer: wgpu.metadataBuffer,count: 1)
            let m = try XCTUnwrap(counters.first)
            XCTAssertEqual(snapshot.aliveParticleCount,Int(m.aliveCount)); XCTAssertEqual(snapshot.expiredParticleCount,Int(m.expiredCount))
            XCTAssertEqual(snapshot.collisionEventCount,Int(m.collisionCount)); XCTAssertEqual(snapshot.totalEventCount,Int(m.eventCount))
            XCTAssertEqual(snapshot.compactedParticleCount,Int(m.compactedCount))
            let events: [GPUParticleSimulationEvent] = try wgpuRead(reference.backend,buffer: wgpu.eventBuffer,count: Int(m.eventCount))
            let ordered = events.map(\.record).sorted(by: eventOrder), records = snapshot.records.sorted(by: eventOrder)
            XCTAssertEqual(records.count,ordered.count)
            for (a,b) in zip(records,ordered) {
                XCTAssertEqual(a.trigger,b.trigger); XCTAssertEqual(a.sourceIndex,b.sourceIndex)
                XCTAssertEqual(a.generation,b.generation); XCTAssertEqual(a.appearanceIndex,b.appearanceIndex)
                compare(SIMD4(a.position,a.lifetime),SIMD4(b.position,b.lifetime)); compare(SIMD4(a.velocity,a.age),SIMD4(b.velocity,b.age))
            }
            XCTAssertEqual(update.report.particleCount,pair.1)
            XCTAssertEqual(update.report.dispatchWorkgroups,(pair.1+pair.0-1)/pair.0)
            try device.beginFrame(); let repeatCommands = CommandBuffer()
            let repeated = try simulation.prepare(scene: scene,deltaTime: 0.2,elapsedTime: 1.7,into: repeatCommands)
            try device.submit(repeatCommands); simulation.commit(repeated); device.endFrame()
            let resetStates = try nativeStates(device: device,state: native).filter { $0.positionLifetime.w > 0 }.sorted { $0.params.z < $1.params.z }
            XCTAssertEqual(actual.count,resetStates.count)
            for (a,b) in zip(actual,resetStates) {
                XCTAssertEqual(a.params,b.params); compare(a.positionLifetime,b.positionLifetime); compare(a.velocityAge,b.velocityAge)
            }
            _ = try simulation.drain(maxSnapshots: 1)
        }
    }
    private func eventOrder(_ a: GPUParticleSimulationEventRecord, _ b: GPUParticleSimulationEventRecord) -> Bool {
        a.sourceIndex == b.sourceIndex ? a.trigger.rawValue < b.trigger.rawValue : a.sourceIndex < b.sourceIndex
    }
    private func lifecycle(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false,framesInFlight: 3))
        let simulation = NativeParticleSimulation(device: device)
        let a = EntityID(rawValue: 11), b = EntityID(rawValue: 22)
        let plan = ParticleEmitter(settings: .init {
            $0.emission.maxParticles = 2; $0.gpuSimulation.simulationBackend = .gpuRequired; $0.gpuSimulation.workgroupSize = 37
        }).gpuSimulationPlan
        let particle = Particle(position: .zero,velocity: SIMD3(1,0,0),lifetime: 100)
        var batchA = RenderParticleSimulationBatch(emitterEntity: a,plan: plan,particles: [particle],gravity: .zero)
        var batchB = batchA; batchB.emitterEntity = b; batchB.particles[0].position.x = 10
        func frame(_ batches: [RenderParticleSimulationBatch], dt: Float = 1, submit: Bool = true) throws -> NativeParticleSimulationUpdate {
            try device.beginFrame(); defer { device.endFrame() }; let commands = CommandBuffer()
            let update = try simulation.prepare(scene: RenderScene(camera: RenderCamera(eye: SIMD3(0,0,5),target: .zero),particleSimulationBatches: batches),deltaTime: dt,elapsedTime: 0,into: commands)
            if submit { try device.submit(commands); simulation.commit(update) }
            return update
        }
        _ = try frame([batchA,batchB])
        let oldA = try XCTUnwrap(simulation.entries[.emitter(a.rawValue)]?.state)
        _ = try frame([batchB,batchA])
        XCTAssertTrue(simulation.entries[.emitter(a.rawValue)]?.state === oldA)
        XCTAssertEqual(try nativeStates(device: device,state: oldA)[0].positionLifetime.x,2,accuracy: 0.0001)
        XCTAssertEqual(try nativeStates(device: device,state: XCTUnwrap(simulation.entries[.emitter(b.rawValue)]?.state))[0].positionLifetime.x,12,accuracy: 0.0001)
        XCTAssertTrue(try simulation.drain(maxSnapshots: 0).isEmpty)
        let first = try XCTUnwrap(simulation.drain(maxSnapshots: 1).first)
        XCTAssertEqual(first.emitterRawValue,a.rawValue); XCTAssertEqual(first.slot,0); XCTAssertEqual(first.aliveParticleCount,1)
        let rest = try simulation.drain(maxSnapshots: 64)
        XCTAssertEqual(rest.map(\.emitterRawValue),[b.rawValue,b.rawValue,a.rawValue]); XCTAssertEqual(rest.map(\.slot),[1,0,1])
        // Rejected recording does not execute physics or advance residency.
        _ = try frame([batchA],dt: 3,submit: false)
        XCTAssertEqual(try nativeStates(device: device,state: oldA)[0].positionLifetime.x,2,accuracy: 0.0001)
        XCTAssertEqual(simulation.entries.count,2); XCTAssertTrue(try simulation.drain(maxSnapshots: 64).isEmpty)
        // A spawn can fill the resident spare slot; the next frame drops excess spawns.
        batchA.particles = []; batchA.spawnParticles = [Particle(position: SIMD3(4,0,0),velocity: .zero,lifetime: 100,generation: 3,appearanceIndex: 7)]
        _ = try frame([batchA],dt: 0)
        var snapshot = try XCTUnwrap(simulation.drain(maxSnapshots: 1).first)
        XCTAssertEqual(snapshot.gpuSpawnedParticleCount,1); XCTAssertEqual(snapshot.compactedParticleCount,2)
        _ = try frame([batchA],dt: 0)
        snapshot = try XCTUnwrap(simulation.drain(maxSnapshots: 1).first)
        XCTAssertEqual(snapshot.gpuSpawnedParticleCount,0); XCTAssertEqual(snapshot.gpuDroppedSpawnCount,1)
        // Empty payload removes residency, and restoring it uses the supplied seed.
        _ = try frame([]); XCTAssertTrue(simulation.entries.isEmpty)
        batchA.particles = [particle]; batchA.spawnParticles = []
        _ = try frame([batchA])
        let reset = try XCTUnwrap(simulation.entries[.emitter(a.rawValue)]?.state)
        XCTAssertFalse(reset === oldA); XCTAssertEqual(try nativeStates(device: device,state: reset)[0].positionLifetime.x,1,accuracy: 0.0001)
        batchA.plan.workgroupSize = 255
        _ = try frame([batchA])
        let regrouped = try XCTUnwrap(simulation.entries[.emitter(a.rawValue)]?.state)
        XCTAssertFalse(regrouped === reset); XCTAssertEqual(try nativeStates(device: device,state: regrouped)[0].positionLifetime.x,1,accuracy: 0.0001)
        batchA.plan.particleCapacity = 5
        _ = try frame([batchA]); XCTAssertEqual(simulation.entries[.emitter(a.rawValue)]?.state.capacity,5)
        batchA.emitterEntity = nil
        _ = try frame([batchA]); _ = try frame([batchA])
        XCTAssertEqual(try nativeStates(device: device,state: XCTUnwrap(simulation.entries[.anonymous(0)]?.state))[0].positionLifetime.x,1,accuracy: 0.0001)
        _ = try simulation.drain(maxSnapshots: 64)
        for _ in 0..<66 { _ = try frame([batchA],dt: 0) }
        XCTAssertEqual(try simulation.drain(maxSnapshots: Int.max).count,64)
        XCTAssertTrue(try simulation.drain(maxSnapshots: Int.max).isEmpty)
    }
    private func rendererEvents(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let renderer = try NativeRenderer(device: device)
        var packet = MeshProbeScene.packet(size: .init(width: 64,height: 64))
        packet.scene.particleSimulationBatches = [makeBatch(group: 37,count: 3)]; packet.deltaTime = 0.2
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationBatchCount,1)
        XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationParticleCount,3)
        XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationDispatchWorkgroups,1)
        XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationEventCapacity,12)
        XCTAssertEqual(try renderer.drainGPUParticleSimulationEventSnapshots(maxSnapshots: 1).count,1)
        packet.scene.particleSimulationBatches[0].forceStrength = .nan
        XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
        packet.scene.particleSimulationBatches[0].forceStrength = 0.4; packet.frameIndex += 1
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(try renderer.drainGPUParticleSimulationEventSnapshots(maxSnapshots: 1).count,1)
        packet.scene.particleSimulationBatches = []; packet.frameIndex += 1
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationBatchCount,0)
        XCTAssertTrue(renderer.particleSimulation.entries.isEmpty)
    }
    private func nativeStates(device: Device, state: NativeParticleSimulationState) throws -> [GPUParticleSimulationState] {
        var data = Data(count: state.capacity*80)
        try data.withUnsafeMutableBytes { try device.readBufferData(state.state,into: $0) }
        return data.withUnsafeBytes { raw in (0..<state.capacity).map { raw.loadUnaligned(fromByteOffset: $0*80,as: GPUParticleSimulationState.self) } }
    }
    private func wgpuRead<T>(_ backend: WGPUBackend, buffer: GPUBuffer, count: Int) throws -> [T] {
        guard count > 0 else { return [] }
        let size = UInt64(count*MemoryLayout<T>.stride)
        let readback = try backend.createBuffer(size: size,usage: [.copyDst,.mapRead]), encoder = try backend.createCommandEncoder()
        encoder.copyBufferToBuffer(source: buffer,destination: readback,size: size); backend.submit(try encoder.finish())
        try backend.bufferMapSync(readback,size: size); defer { readback.unmap() }
        let pointer = try XCTUnwrap(readback.getMappedRange(size: size))
        return (0..<count).map { pointer.loadUnaligned(fromByteOffset: $0*MemoryLayout<T>.stride,as: T.self) }
    }
    private func compare(_ a: SIMD4<Float>, _ b: SIMD4<Float>, file: StaticString = #filePath, line: UInt = #line) {
        for axis in 0..<4 { XCTAssertEqual(a[axis],b[axis],accuracy: 0.0005,file: file,line: line) }
    }
}
