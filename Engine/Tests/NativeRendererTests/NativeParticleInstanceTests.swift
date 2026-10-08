import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import RHIWGPU
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeParticleInstanceTests: XCTestCase {
    func testInstanceLayoutsAndTruncatedCurvePacking() throws {
        XCTAssertEqual(MemoryLayout<GPUParticleSimulationInstanceUniforms>.stride,240)
        XCTAssertEqual(MemoryLayout<GPUParticleAppearance>.stride,48)
        XCTAssertEqual(MemoryLayout<GPUParticleCurveKeyframe>.stride,16)
        XCTAssertEqual(MemoryLayout<GPUParticleSortItem>.stride,16)
        XCTAssertEqual(MemoryLayout<GPUParticleSortPrepareUniforms>.stride,96)
        XCTAssertEqual(MemoryLayout<GPUParticleSortBitonicUniforms>.stride,16)
        for api in [GraphicsAPI.metal,.vulkan] {
            let shader = try NativeShaderLibrary.artifact(name: "particle_sim_to_instance",api: api,stage: .compute)
            XCTAssertEqual(shader.interface.threadgroupSpecialization.x,0)
            XCTAssertEqual(shader.interface.bindings.first { $0.slot == 2 }?.buffer.elementStride,112)
            XCTAssertEqual(shader.interface.bindings.first { $0.slot == 4 }?.buffer.elementStride,48)
        }
        var batch = makeBatch(group: 37,scenario: 0)
        batch.sizeCurve = .keyframes((0..<150).map { .init(time: Float($0)/149,value: Float($0)) })
        batch.colorCurve = .keyframes([.init(time: 0,value: 0),.init(time: 1,value: 1)])
        let data = GPUParticleAppearanceData(batch: batch)
        XCTAssertEqual(data.keyframes.count,128)
        XCTAssertEqual(data.keyframes.last?.timeValue,SIMD4(1,149,0,0))
        XCTAssertEqual(data.sizeCurve.keyframeRange,SIMD2(0,128))
        XCTAssertEqual(data.colorCurve.modeConstant,.zero)
        XCTAssertEqual(GPUParticleSortPlan(count: 131).capacity,256)
        XCTAssertEqual(GPUParticleSortPlan(count: 131).stages.count,36)
    }
    #if os(macOS)
    func testMetalSortAndInstancesMatchProductionWGSL() throws { try kernels(.metal) }
    func testMetalSimulatedParticlesMixedDrawAndPostParity() throws { try parity(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanSortAndInstancesMatchProductionWGSL() throws { try kernels(.vulkan) }
    func testVulkanSimulatedParticlesMixedDrawAndPostParity() throws { try parity(.vulkan) }
    #endif
    private func makeBatch(group: Int, scenario: Int) -> RenderParticleSimulationBatch {
        let plan = ParticleEmitter(settings: .init {
            $0.emission.maxParticles = 137; $0.gpuSimulation.simulationBackend = .gpuRequired; $0.gpuSimulation.workgroupSize = group
        }).gpuSimulationPlan
        let particles: [Particle] = (0..<131).map { (index: Int) -> Particle in
            let position = SIMD3<Float>(Float(index%13)*0.08-0.4,Float(index%7)*0.06,Float(index%11)*0.04)
            let velocity: SIMD3<Float> = index%5 == 0 ? .zero : SIMD3(0.2,0.1,-0.3)
            let lifetime: Float = index%19 == 0 ? 0 : index%23 == 0 ? 0.2 : 3
            let color = SIMD4<Float>(0.9,0.3+Float(index%3)*0.2,0.4,0.7)
            return Particle(position: position,velocity: velocity,age: Float(index%9)*0.13,lifetime: lifetime,
                sizeScale: 0.7,rotation: Float(index)*0.05,angularVelocity: 0.6,size: 0.12,color: color,
                appearanceIndex: UInt16(index%5),textureFrameSeed: UInt16(index*7))
        }
        var batch = RenderParticleSimulationBatch(plan: plan,particles: particles,gravity: .zero,renderOnGPU: true)
        batch.uvRect = SIMD4(0.1,0.2,0.8,0.7)
        batch.textureSheetColumns = 4; batch.textureSheetRows = 3; batch.textureSheetFrameCount = 8
        batch.textureSheetFrameRate = scenario%2 == 0 ? 0 : 3
        batch.textureSheetStartFrame = 2; batch.textureSheetFrameRandomness = 5
        batch.startSize = 0.3; batch.endSize = 0.06
        batch.startColor = SIMD4(1,0.2,0.4,0.8); batch.endColor = SIMD4(0.1,0.8,1,0.2)
        batch.usesAuthoredAppearance = scenario%3 != 0
        batch.appearancePalette = [.init(startSize: 0.2,endSize: 0.05,startColor: SIMD4(1,0,0,0.8),endColor: SIMD4(0,0,1,0.3)),
            .init(startSize: 0.3,endSize: 0.1,startColor: SIMD4(0,1,0,0.6),endColor: SIMD4(1,1,0,0.1))]
        batch.renderAlignment = scenario%2 == 0 ? .billboard : .velocity
        batch.velocityStretchScale = 2; batch.velocityStretchMax = 3
        batch.renderParticleLimit = scenario%2 == 0 ? 0 : 67; batch.renderAlphaScale = 0.75
        batch.trailLength = scenario%3 == 1 ? 0 : 0.8; batch.trailSegments = 3
        batch.trailEndSizeScale = 0.15; batch.trailEndAlphaScale = 0.1
        let curves: [ParticleCurve] = [.constant(0.4),.linear,.easeIn,.easeOut,.easeInOut,
            .keyframes([.init(time: 1,value: 0.7),.init(time: 0.3,value: 0.2),.init(time: 0,value: 0),.init(time: 0.3,value: 0.6)]),.keyframes([])]
        batch.sizeCurve = curves[scenario%curves.count]; batch.colorCurve = curves[(scenario+2)%curves.count]
        let sorting: [ParticleSortMode] = [.distanceDescending,.distanceAscending,.oldestFirst,.youngestFirst]
        let playback: [ParticleTextureSheetPlaybackMode] = [.automatic,.lifetime,.playOnce,.loop,.singleFrame]
        batch.sortMode = sorting[scenario%sorting.count]; batch.textureSheetPlaybackMode = playback[scenario%playback.count]
        batch.worldTransform.columns.0 = SIMD4(0.8,0.4,0,0); batch.worldTransform.columns.1 = SIMD4(-0.3,1.1,0,0)
        batch.worldTransform.columns.3 = SIMD4(0.2,0.3,-0.4,1)
        return batch
    }
    private func kernels(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let reference = try WGPUSceneReference(validation: true)
        var programs: [Int: NativeParticleInstanceKernels] = [:]
        for scenario in 0..<24 {
            let group = [1,37,64,255,256][scenario%5]
            var batch = makeBatch(group: group,scenario: scenario)
            if scenario >= 20 {
                batch.appearancePalette = (0..<70).map { .init(startSize: Float($0)*0.01,endSize: 0.04,startColor: SIMD4(0.2,0.8,0.1,0.7),endColor: SIMD4(1,0.1,0.3,0)) }
                batch.particles[2].appearanceIndex = 69; batch.particles[1].appearanceIndex = 63
                batch.sizeCurve = .keyframes((0..<150).map { .init(time: Float($0)/149,value: Float($0)/150) })
                batch.colorCurve = .keyframes([.init(time: 0,value: 0),.init(time: 1,value: 1)])
            }
            if programs[group] == nil { programs[group] = try NativeParticleInstanceKernels(device: device,workgroupSize: group) }
            let state = try NativeParticleSimulationState(device: device,capacity: batch.plan.particleCapacity)
            let sort = try NativeParticleSortBuffer(device: device,count: batch.renderParticleCount)
            let base = 11, count = base+batch.renderInstanceCount
            let source = try NativeParticleSourceBuffer(device: device,capacity: count+5)
            let states = batch.particles.map { GPUParticleSimulationState(particle: $0) }, data = states.withUnsafeBytes { Data($0) }
            try device.uploadBufferData(state.state,data: data)
            try device.uploadBufferData(source.buffer,data: Data(repeating: 0x3f,count: source.capacity*112))
            try device.beginFrame(); let commands = CommandBuffer()
            let report = try programs[group]!.encode(batch: batch,state: state,sort: sort,cameraEye: SIMD3(0,1,5),source: source,baseInstance: base,into: commands)
            try device.submit(commands); device.endFrame()
            let resources = try XCTUnwrap(reference.renderer.ensureParticleSimulationResources(for: batch.plan))
            data.withUnsafeBytes { reference.backend.writeBuffer(resources.stateBuffer,data: $0.baseAddress!,size: $0.count) }
            try reference.renderer.ensureParticleStorageCapacity(count: source.capacity)
            let expectedBuffer = try XCTUnwrap(reference.renderer.particleStorageBuffer)
            Data(repeating: 0x3f,count: source.capacity*112).withUnsafeBytes { reference.backend.writeBuffer(expectedBuffer,data: $0.baseAddress!,size: $0.count) }
            reference.renderer.gpuParticleRenderInstanceCount = base
            let encoder = try reference.backend.createCommandEncoder()
            let expectedReport = try reference.renderer.encodeParticleSimulationInstancePass(encoder: encoder,resources: resources,batch: batch,
                cameraEye: SIMD3(0,1,5),particleCount: batch.particleCount,workgroupSize: group)
            reference.backend.submit(try encoder.finish())
            var bytes = Data(count: source.capacity*112)
            try bytes.withUnsafeMutableBytes { try device.readBufferData(source.buffer,into: $0) }
            let expected: [GPUParticleInstance] = try read(reference.backend,buffer: expectedBuffer,count: source.capacity)
            let instances = bytes.withUnsafeBytes { raw in (0..<source.capacity).map { raw.loadUnaligned(fromByteOffset: $0*112,as: GPUParticleInstance.self) } }
            for (index,pair) in zip(instances,expected).enumerated() {
                withUnsafeBytes(of: pair.0) { actual in withUnsafeBytes(of: pair.1) { target in
                    for (a,b) in zip(actual.bindMemory(to: Float.self),target.bindMemory(to: Float.self)) {
                        XCTAssertEqual(a,b,accuracy: 0.0001,"scenario \(scenario), instance \(index)")
                    }
                } }
            }
            var sorted = Data(count: sort.capacity*16)
            try sorted.withUnsafeMutableBytes { try device.readBufferData(sort.buffer,into: $0) }
            let expectedItems: [GPUParticleSortItem] = try read(reference.backend,buffer: resources.sortItemBuffer,count: sort.capacity)
            sorted.withUnsafeBytes { raw in
                for (index,item) in expectedItems.enumerated() {
                    let actual = raw.loadUnaligned(fromByteOffset: index*16,as: GPUParticleSortItem.self)
                    XCTAssertEqual(actual.index,item.index,"scenario \(scenario)")
                    XCTAssertEqual(actual.key,item.key,accuracy: 0.0001)
                }
            }
            XCTAssertEqual(report.renderInstanceCount,expectedReport.renderInstanceCount)
            XCTAssertEqual(report.instanceDispatchWorkgroups,expectedReport.instanceDispatchWorkgroups)
            XCTAssertEqual(report.sortReport.passCount,expectedReport.sortReport.passCount)
            XCTAssertEqual(report.sortReport.dispatchWorkgroups,expectedReport.sortReport.dispatchWorkgroups)
        }
    }
    private func parity(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false,framesInFlight: 3))
        let renderer = try NativeRenderer(device: device), reference = try WGPUSceneReference(validation: true)
        var packet = MeshProbeScene.packet(size: .init(width: 256,height: 192))
        packet.renderSettings.enableEditorGrid = false; packet.renderSettings.debugViewMode = .unlit
        packet.scene.camera = RenderCamera(eye: SIMD3(0,1,5),target: SIMD3(0,0.4,0),near: 0.1,far: 100)
        packet.scene.particles = [RenderParticle(position: SIMD3(0.6,0.4,0.5),size: 0.3,color: SIMD4(0.4,0.8,1,0.6),blendMode: .additive)]
        let atlasURL = FileManager.default.temporaryDirectory.appendingPathComponent("guava-particle-atlas-\(UUID().uuidString).bmp")
        try atlasFixture().write(to: atlasURL)
        defer { try? FileManager.default.removeItem(at: atlasURL) }
        var snapshots: [Data] = []
        for frame in 0..<22 {
            packet.frameIndex = frame; packet.deltaTime = 0.02; packet.simulationTimeSeconds = Double(frame)*0.02
            var a = makeBatch(group: 37,scenario: frame), b = makeBatch(group: 255,scenario: frame+1)
            a.emitterEntity = EntityID(rawValue: 11); b.emitterEntity = EntityID(rawValue: 22); b.blendMode = .additive
            b.worldTransform.columns.3.x += 0.6
            a.texturePath = atlasURL.path; b.texturePath = atlasURL.path
            if frame == 6 { a.spawnParticles = [Particle(position: SIMD3(0,0.4,1),velocity: .zero,lifetime: 3,color: SIMD4(1,0,1,0.8))] }
            packet.scene.particleSimulationBatches = frame%2 == 0 ? [a,b] : [b,a]
            if frame == 8 { packet.scene.particleSimulationBatches = [] }
            if frame == 10 { packet.drawableSize = .init(width: 320,height: 200) }
            if frame == 12 { packet.drawableSize = .init(width: 192,height: 128) }
            if frame >= 14 {
                packet.renderSettings.stage = .r5PostProcess; packet.renderSettings.debugViewMode = .shaded
                packet.renderSettings.enableBloom = true; packet.renderSettings.enableTAA = true; packet.renderSettings.enableFXAA = true
            }
            try renderer.renderChecked(packet: packet); let expectedStats = try reference.render(packet: packet)
            let actual = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
            let expected = try reference.readback(), difference = try GridImage.difference(actual,expected)
            print("native simulated-particle frame \(frame): \(difference)")
            XCTAssertLessThan(difference.meanAbsoluteChannelError,0.5); XCTAssertLessThan(difference.pixelsOverThree,max(1,difference.pixelCount/100))
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationParticleCount,expectedStats.gpuParticleSimulationParticleCount)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleSimulationDispatchWorkgroups,expectedStats.gpuParticleSimulationDispatchWorkgroups)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleInstanceDispatchWorkgroups,expectedStats.gpuParticleInstanceDispatchWorkgroups)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleRenderInstanceCount,expectedStats.gpuParticleRenderInstanceCount)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleSortPassCount,expectedStats.gpuParticleSortPassCount)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleSortDispatchWorkgroups,expectedStats.gpuParticleSortDispatchWorkgroups)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleCullCandidateCount,expectedStats.gpuParticleCullCandidateCount)
            XCTAssertEqual(renderer.lastFrameStats.gpuParticleIndirectDrawCount,expectedStats.gpuParticleIndirectDrawCount)
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.particles],expectedStats.passDrawCallCounts[.particles])
            XCTAssertEqual(try renderer.drainGPUParticleSimulationEventSnapshots(maxSnapshots: 64).count,try reference.renderer.drainGPUParticleSimulationEventSnapshots(maxSnapshots: 64).count)
            if let source = renderer.particleSimulation.source {
                let count = expectedStats.gpuParticleRenderInstanceCount
                var sourceData = Data(count: count*112)
                try sourceData.withUnsafeMutableBytes { try device.readBufferData(source.buffer,into: $0) }
                let otherSource = try XCTUnwrap(reference.renderer.particleStorageBuffer)
                let expectedInstances: [GPUParticleInstance] = try read(reference.backend,buffer: otherSource,count: count)
                var differingInstances = 0
                sourceData.withUnsafeBytes { raw in
                    for (index,target) in expectedInstances.enumerated() {
                        let item = raw.loadUnaligned(fromByteOffset: index*112,as: GPUParticleInstance.self)
                        withUnsafeBytes(of: item) { lhs in withUnsafeBytes(of: target) { rhs in
                            let pairs = zip(lhs.bindMemory(to: Float.self),rhs.bindMemory(to: Float.self))
                            if pairs.contains(where: { !$0.isFinite || !$1.isFinite || abs($0-$1) > 0.0001 }) {
                                differingInstances += 1
                            }
                        } }
                    }
                }
                XCTAssertEqual(differingInstances,0,"frame \(frame) converted instances")
                for id: UInt64 in [11,22] {
                    let resident = try XCTUnwrap(renderer.particleSimulation.entries[.emitter(id)]?.state)
                    var stateData = Data(count: resident.capacity*80)
                    try stateData.withUnsafeMutableBytes { try device.readBufferData(resident.state,into: $0) }
                    let other = try XCTUnwrap(reference.renderer.particleSimulationResourcesByEmitter[id])
                    let expectedStates: [GPUParticleSimulationState] = try read(reference.backend,buffer: other.stateBuffer,count: other.capacity)
                    let differing = stateData.withUnsafeBytes { raw in expectedStates.enumerated().filter { index,target in
                        let item = raw.loadUnaligned(fromByteOffset: index*80,as: GPUParticleSimulationState.self)
                        if item.params != target.params { return true }
                        return withUnsafeBytes(of: item) { lhs in withUnsafeBytes(of: target) { rhs in
                            zip(lhs.bindMemory(to: Float.self).prefix(16),rhs.bindMemory(to: Float.self).prefix(16))
                                .contains { !$0.isFinite || !$1.isFinite || abs($0-$1) > 0.0001 }
                        } }
                    }.count }
                    XCTAssertEqual(differing,0,"frame \(frame) emitter \(id) resident states")
                }
            }
            snapshots.append(actual)
        }
        XCTAssertNotEqual(snapshots[0],snapshots[1])
    }
    private func atlasFixture() -> Data {
        // Twelve distinct atlas cells, decoded through the production BMP path.
        var data = Data([0x42,0x4d])
        func append(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        append(54+8*6*4); append(0); append(54); append(40); append(8); append(6)
        data.append(contentsOf: [1,0,32,0]); append(0); append(8*6*4); append(0); append(0); append(0); append(0)
        for y in 0..<6 { for x in 0..<8 {
            let cell = (y/2)*4+x/2
            data.append(contentsOf: [UInt8(20+cell*19),UInt8(240-cell*17),UInt8(30+(cell*53)%210),UInt8(80+cell*15)])
        } }
        return data
    }
    private func read<T>(_ backend: WGPUBackend, buffer: GPUBuffer, count: Int) throws -> [T] {
        let size = UInt64(count*MemoryLayout<T>.stride), target = try backend.createBuffer(size: UInt64(count*MemoryLayout<T>.stride),usage: [.copyDst,.mapRead])
        let encoder = try backend.createCommandEncoder(); encoder.copyBufferToBuffer(source: buffer,destination: target,size: size)
        backend.submit(try encoder.finish()); try backend.bufferMapSync(target,size: size); defer { target.unmap() }
        let pointer = try XCTUnwrap(target.getMappedRange(size: size))
        return (0..<count).map { pointer.loadUnaligned(fromByteOffset: $0*MemoryLayout<T>.stride,as: T.self) }
    }
}
