import Foundation
import NativeRHI
import SceneRuntime

/// Resident simulation data is transient and follows an emitter, never the batch slot.
final class NativeParticleSimulationState {
    let device: Device
    let capacity: Int
    let eventCapacity: Int
    let state: Buffer
    let compact: Buffer
    let metadata: Buffer
    let events: Buffer
    init(device: Device, capacity: Int) throws {
        guard capacity > 0, capacity <= GPUParticleSimulationUniforms.maximumExactParticleCount else {
            throw RHIError.invalidArgument("particle capacity exceeds the Float32 simulation ABI")
        }
        self.device = device; self.capacity = capacity; eventCapacity = max(1,capacity*2)
        var allocated: [Buffer] = []
        func buffer(_ size: Int) throws -> Buffer {
            let result = try device.makeBuffer(BufferDescriptor(size: size,usage: [.storageRead,.storageWrite,.transferSource,.transferDestination]))
            allocated.append(result); return result
        }
        do {
            state = try buffer(capacity*MemoryLayout<GPUParticleSimulationState>.stride)
            compact = try buffer(capacity*MemoryLayout<GPUParticleSimulationState>.stride)
            metadata = try buffer(MemoryLayout<GPUParticleSimulationMetadata>.stride)
            events = try buffer(eventCapacity*MemoryLayout<GPUParticleSimulationEvent>.stride)
        } catch { allocated.forEach { device.destroy($0) }; throw error }
    }
    deinit { [state,compact,metadata,events].forEach { device.destroy($0) } }
}

enum NativeParticleSimulationKey: Hashable {
    case emitter(UInt64)
    case anonymous(Int)
    init(batch: RenderParticleSimulationBatch, slot: Int) {
        self = batch.emitterEntity.map { .emitter($0.rawValue) } ?? .anonymous(slot)
    }
}

struct NativeParticleSimulationEntry {
    let state: NativeParticleSimulationState
    let workgroupSize: Int
    var initialized = false
}

/// A frame owns its proposed residency and snapshots until submission succeeds.
struct NativeParticleSimulationUpdate {
    var entries: [NativeParticleSimulationKey: NativeParticleSimulationEntry] = [:]
    var readbacks: [NativeParticleSimulationReadback] = []
    var report = GPUParticleSimulationEncodeReport()
}

final class NativeParticleSimulation {
    private let device: Device
    private var programs: [Int: NativeParticleSimulationKernels] = [:]
    private(set) var entries: [NativeParticleSimulationKey: NativeParticleSimulationEntry] = [:]
    private var pending: [NativeParticleSimulationReadback] = []
    init(device: Device) { self.device = device }

    func prepare(scene: RenderScene, deltaTime: Float, elapsedTime: Float, into commands: CommandBuffer) throws -> NativeParticleSimulationUpdate {
        var update = NativeParticleSimulationUpdate()
        for (slot,batch) in scene.particleSimulationBatches.enumerated() where batch.plan.usesGPU && batch.particleCount > 0 {
            let key = NativeParticleSimulationKey(batch: batch,slot: slot)
            guard update.entries[key] == nil else { throw RHIError.invalidArgument("duplicate particle simulation emitter") }
            let group = min(256,max(1,batch.plan.workgroupSize)), capacity = batch.plan.particleCapacity
            var entry: NativeParticleSimulationEntry
            if let previous = entries[key], previous.state.capacity >= capacity, previous.workgroupSize == group {
                entry = previous
            } else {
                entry = NativeParticleSimulationEntry(state: try NativeParticleSimulationState(device: device,capacity: capacity),workgroupSize: group)
            }
            if programs[group] == nil { programs[group] = try NativeParticleSimulationKernels(device: device,workgroupSize: group) }
            guard let kernels = programs[group] else { throw RHIError.outOfMemory }
            let reseed = batch.emitterEntity == nil || !entry.initialized
            let count = try kernels.encode(batch: batch,state: entry.state,reseed: reseed,
                deltaTime: deltaTime*batch.simulationSpeed,elapsedTime: elapsedTime,into: commands)
            entry.initialized = true; update.entries[key] = entry
            update.readbacks.append(try NativeParticleSimulationReadback(device: device,state: entry.state,slot: slot,emitter: batch.emitterEntity?.rawValue,into: commands))
            update.report.batchCount += 1; update.report.particleCount += count
            update.report.dispatchWorkgroups += (count+group-1)/group
            update.report.eventCapacity += entry.state.eventCapacity
            update.report.eventBufferBytes += entry.state.eventCapacity*MemoryLayout<GPUParticleSimulationEvent>.stride
        }
        return update
    }
    func commit(_ update: NativeParticleSimulationUpdate) {
        entries = update.entries
        pending.append(contentsOf: update.readbacks)
        if pending.count > 64 { pending.removeFirst(pending.count-64) }
    }
    func drain(maxSnapshots: Int) throws -> [GPUParticleSimulationEventSnapshot] {
        var result: [GPUParticleSimulationEventSnapshot] = []
        for _ in 0..<min(max(0,maxSnapshots),pending.count) {
            // A failed read remains queued, so retrying does not lose events.
            result.append(try pending[0].read()); pending.removeFirst()
        }
        return result
    }
}
