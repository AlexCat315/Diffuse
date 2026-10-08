import Foundation
import NativeRHI
import SceneRuntime

/// Physics and lifecycle programs for one physical workgroup size.
final class NativeParticleSimulationKernels {
    private let device: Device
    private let workgroupSize: Int
    private let simulate: NativeComputePass
    private let spawn: NativeComputePass
    private let clear: NativeComputePass
    private let compact: NativeComputePass
    private let reset: NativeComputePass
    private let finalize: NativeComputePass
    init(device: Device, workgroupSize: Int) throws {
        self.device = device; self.workgroupSize = workgroupSize
        let state = MemoryLayout<GPUParticleSimulationState>.stride, metadata = MemoryLayout<GPUParticleSimulationMetadata>.stride
        simulate = try NativeComputePass(device: device,shader: "particle_simulate",bufferStrides: [1: state,2: metadata,3: MemoryLayout<GPUParticleSimulationEvent>.stride],workgroupSize: workgroupSize)
        spawn = try NativeComputePass(device: device,shader: "particle_spawn_append",bufferStrides: [1: state,2: state,3: metadata],workgroupSize: workgroupSize)
        clear = try NativeComputePass(device: device,shader: "particle_state_clear",bufferStrides: [1: state],workgroupSize: workgroupSize)
        compact = try NativeComputePass(device: device,shader: "particle_state_compact",bufferStrides: [1: state,2: state,3: metadata],workgroupSize: workgroupSize)
        reset = try NativeComputePass(device: device,shader: "particle_metadata_reset",bufferStrides: [0: metadata])
        finalize = try NativeComputePass(device: device,shader: "particle_state_finalize",bufferStrides: [0: metadata])
    }
    func encode(batch: RenderParticleSimulationBatch, state: NativeParticleSimulationState, reseed: Bool,
                deltaTime: Float, elapsedTime: Float, into commands: CommandBuffer) throws -> Int {
        let persisted = min(batch.particles.count,state.capacity,batch.plan.particleCapacity)
        let requested = min(batch.spawnParticles.count,state.capacity)
        let seededSpawn = min(requested,max(0,batch.plan.particleCapacity-persisted))
        let count = reseed ? persisted+seededSpawn : state.capacity
        let maintenance = try NativeUniformUpload.binding(GPUParticleStateMaintenanceUniforms(params: SIMD4(UInt32(count),UInt32(state.capacity),0,0)),device: device)
        if reseed {
            // Allocation and anonymous reseeding must clear the unused tail too.
            try clear.encode(entries: [.init(slot: 0,resource: maintenance),.init(slot: 1,resource: .storageBuffer(buffer: state.state))],groups: groups(state.capacity),into: commands)
            let particles = batch.particles.prefix(persisted).map { GPUParticleSimulationState(particle: $0) }
            try copy(particles.withUnsafeBytes { Data($0) },to: state.state,into: commands)
            var metadata = GPUParticleSimulationMetadata(appendCursor: persisted)
            try copy(withUnsafeBytes(of: &metadata) { Data($0) },to: state.metadata,into: commands)
        } else {
            try reset.encode(entries: [.init(slot: 0,resource: .storageBuffer(buffer: state.metadata))],groups: 1,into: commands)
        }
        if requested > 0 {
            let states = batch.spawnParticles.prefix(requested).map { GPUParticleSimulationState(particle: $0) }
            let input = try device.uploadTransient(states.withUnsafeBytes { Data($0) })
            let uniform = try NativeUniformUpload.binding(GPUParticleSpawnUniforms(params: SIMD4(UInt32(requested),UInt32(state.capacity),0,0)),device: device)
            try spawn.encode(entries: [.init(slot: 0,resource: uniform),.init(slot: 1,resource: .storageBuffer(buffer: input.buffer,offset: input.offset)),
                .init(slot: 2,resource: .storageBuffer(buffer: state.state)),.init(slot: 3,resource: .storageBuffer(buffer: state.metadata))],groups: groups(requested),into: commands)
        }
        let uniforms = GPUParticleSimulationUniforms(batch: batch,deltaTime: deltaTime,elapsedTime: elapsedTime,dispatchCount: count,eventCapacity: state.eventCapacity)
        try simulate.encode(entries: [.init(slot: 0,resource: NativeUniformUpload.binding(uniforms,device: device)),
            .init(slot: 1,resource: .storageBuffer(buffer: state.state)),.init(slot: 2,resource: .storageBuffer(buffer: state.metadata)),
            .init(slot: 3,resource: .storageBuffer(buffer: state.events))],groups: groups(count),into: commands)
        try clear.encode(entries: [.init(slot: 0,resource: maintenance),.init(slot: 1,resource: .storageBuffer(buffer: state.compact))],groups: groups(state.capacity),into: commands)
        try compact.encode(entries: [.init(slot: 0,resource: maintenance),.init(slot: 1,resource: .storageBuffer(buffer: state.state)),
            .init(slot: 2,resource: .storageBuffer(buffer: state.compact)),.init(slot: 3,resource: .storageBuffer(buffer: state.metadata))],groups: groups(count),into: commands)
        try finalize.encode(entries: [.init(slot: 0,resource: .storageBuffer(buffer: state.metadata))],groups: 1,into: commands)
        commands.copyPass { $0.copyBuffer(src: state.compact,dst: state.state,size: state.capacity*MemoryLayout<GPUParticleSimulationState>.stride) }
        return count
    }
    private func groups(_ count: Int) -> Int { max(1,(count+workgroupSize-1)/workgroupSize) }
    private func copy(_ data: Data, to buffer: Buffer, into commands: CommandBuffer) throws {
        guard !data.isEmpty else { return }
        let upload = try device.uploadTransient(data)
        commands.copyPass { $0.copyBuffer(src: upload.buffer,srcOffset: upload.offset,dst: buffer,size: data.count) }
    }
}
