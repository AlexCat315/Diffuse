import Foundation
import NativeRHI

/// Copies each frame's counters/events before the next frame resets them.
final class NativeParticleSimulationReadback {
    private let device: Device
    private let metadata: Buffer
    private let events: Buffer
    private let capacity: Int
    private let slot: Int
    private let emitter: UInt64?
    init(device: Device, state: NativeParticleSimulationState, slot: Int, emitter: UInt64?, into commands: CommandBuffer) throws {
        self.device = device; capacity = state.eventCapacity; self.slot = slot; self.emitter = emitter
        metadata = try device.makeBuffer(BufferDescriptor(size: MemoryLayout<GPUParticleSimulationMetadata>.stride,usage: [.transferDestination,.transferSource]))
        do { events = try device.makeBuffer(BufferDescriptor(size: capacity*MemoryLayout<GPUParticleSimulationEvent>.stride,usage: [.transferDestination,.transferSource])) }
        catch { device.destroy(metadata); throw error }
        commands.copyPass {
            $0.copyBuffer(src: state.metadata,dst: metadata,size: MemoryLayout<GPUParticleSimulationMetadata>.stride)
            $0.copyBuffer(src: state.events,dst: events,size: capacity*MemoryLayout<GPUParticleSimulationEvent>.stride)
        }
    }
    deinit { device.destroy(metadata); device.destroy(events) }
    func read() throws -> GPUParticleSimulationEventSnapshot {
        var counters = GPUParticleSimulationMetadata()
        try withUnsafeMutableBytes(of: &counters) { try device.readBufferData(metadata,into: $0) }
        let count = min(capacity,Int(counters.eventCount)), stride = MemoryLayout<GPUParticleSimulationEvent>.stride
        var data = Data(count: count*stride)
        if count > 0 { try data.withUnsafeMutableBytes { try device.readBufferData(events,into: $0) } }
        let records = data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0*stride,as: GPUParticleSimulationEvent.self).record }
        }
        return counters.snapshot(slot: slot,emitter: emitter,capacity: capacity,records: records)
    }
}
