import Foundation
import NativeRHI
import SceneRuntime

final class NativeParticleSourceBuffer {
    let device: Device
    let buffer: Buffer
    let capacity: Int
    init(device: Device, capacity: Int) throws {
        self.device = device; self.capacity = capacity
        buffer = try device.makeBuffer(BufferDescriptor(size: capacity*MemoryLayout<GPUParticleInstance>.stride,
            usage: [.storageRead,.storageWrite,.transferSource,.transferDestination],label: "native-particle-source"))
    }
    deinit { device.destroy(buffer) }
}
final class NativeParticleSortBuffer {
    let device: Device
    let buffer: Buffer
    let capacity: Int
    init(device: Device, count: Int) throws {
        self.device = device; capacity = GPUParticleSortPlan.capacity(for: count)
        buffer = try device.makeBuffer(BufferDescriptor(size: capacity*MemoryLayout<GPUParticleSortItem>.stride,
            usage: [.storageRead,.storageWrite,.transferSource],label: "native-particle-sort"))
    }
    deinit { device.destroy(buffer) }
}
struct NativeParticleSimulationRender {
    let source: NativeParticleSourceBuffer
    var batches: [ParticleRenderBatch] = []
    var instanceCount = 0
}

/// Sort and conversion programs share a physical workgroup size with simulation.
final class NativeParticleInstanceKernels {
    private let device: Device
    private let workgroupSize: Int
    private let prepare: NativeComputePass
    private let bitonic: NativeComputePass
    private let convert: NativeComputePass
    init(device: Device, workgroupSize: Int) throws {
        self.device = device; self.workgroupSize = workgroupSize
        let state = MemoryLayout<GPUParticleSimulationState>.stride, item = MemoryLayout<GPUParticleSortItem>.stride
        prepare = try NativeComputePass(device: device,shader: "particle_sort_prepare",bufferStrides: [1: state,2: item],workgroupSize: workgroupSize)
        bitonic = try NativeComputePass(device: device,shader: "particle_sort_bitonic",bufferStrides: [1: item],workgroupSize: workgroupSize)
        convert = try NativeComputePass(device: device,shader: "particle_sim_to_instance",bufferStrides: [1: state,2: MemoryLayout<GPUParticleInstance>.stride,
            3: item,4: MemoryLayout<GPUParticleAppearance>.stride,5: MemoryLayout<GPUParticleCurveKeyframe>.stride],workgroupSize: workgroupSize)
    }
    func encode(batch: RenderParticleSimulationBatch, state: NativeParticleSimulationState, sort: NativeParticleSortBuffer,
                cameraEye: SIMD3<Float>, source: NativeParticleSourceBuffer, baseInstance: Int,
                into commands: CommandBuffer) throws -> GPUParticleSimulationInstanceEncodeReport {
        let plan = GPUParticleSortPlan(count: batch.renderParticleCount), sortGroups = groups(plan.capacity)
        try prepare.encode(entries: [
            .init(slot: 0,resource: NativeUniformUpload.binding(GPUParticleSortPrepareUniforms(batch: batch,cameraEye: cameraEye,capacity: plan.capacity),device: device)),
            .init(slot: 1,resource: .storageBuffer(buffer: state.state)),.init(slot: 2,resource: .storageBuffer(buffer: sort.buffer))],groups: sortGroups,into: commands)
        for stage in plan.stages {
            try bitonic.encode(entries: [.init(slot: 0,resource: NativeUniformUpload.binding(stage.uniforms(capacity: plan.capacity),device: device)),
                .init(slot: 1,resource: .storageBuffer(buffer: sort.buffer))],groups: sortGroups,into: commands)
        }
        let appearance = GPUParticleAppearanceData(batch: batch)
        let palette = try device.uploadTransient(appearance.appearances.withUnsafeBytes { Data($0) })
        // A valid storage binding is required even when neither curve reads keys.
        let keys = appearance.keyframes.isEmpty ? [GPUParticleCurveKeyframe(timeValue: .zero)] : appearance.keyframes
        let keyUpload = try device.uploadTransient(keys.withUnsafeBytes { Data($0) })
        let instanceGroups = groups(batch.renderInstanceCount)
        try convert.encode(entries: [
            .init(slot: 0,resource: NativeUniformUpload.binding(GPUParticleSimulationInstanceUniforms(batch: batch,baseInstance: baseInstance,appearance: appearance),device: device)),
            .init(slot: 1,resource: .storageBuffer(buffer: state.state)),.init(slot: 2,resource: .storageBuffer(buffer: source.buffer)),
            .init(slot: 3,resource: .storageBuffer(buffer: sort.buffer)),.init(slot: 4,resource: .storageBuffer(buffer: palette.buffer,offset: palette.offset)),
            .init(slot: 5,resource: .storageBuffer(buffer: keyUpload.buffer,offset: keyUpload.offset))],groups: instanceGroups,into: commands)
        return GPUParticleSimulationInstanceEncodeReport(renderInstanceCount: batch.renderInstanceCount,instanceDispatchWorkgroups: instanceGroups,
            sortReport: GPUParticleSimulationSortEncodeReport(passCount: plan.stages.count+1,itemCount: batch.renderParticleCount,
                paddedItemCount: plan.capacity,dispatchWorkgroups: sortGroups*(plan.stages.count+1)))
    }
    private func groups(_ count: Int) -> Int { (count+workgroupSize-1)/workgroupSize }
}
