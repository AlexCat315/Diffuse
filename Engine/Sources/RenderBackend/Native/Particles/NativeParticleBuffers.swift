import NativeRHI

/// GPU outputs grow independently by responsibility; source instances are frame uploads.
final class NativeParticleBuffers {
    private let device: Device
    private(set) var visible: Buffer?
    private(set) var indirect: Buffer?
    private var instanceCapacity = 0
    private var batchCapacity = 0
    init(device: Device) { self.device = device }
    deinit { if let visible { device.destroy(visible) }; if let indirect { device.destroy(indirect) } }
    func ensure(instances: Int, batches: Int) throws {
        if instances > instanceCapacity {
            let capacity = max(instances,max(instanceCapacity*2,256))
            let next = try device.makeBuffer(BufferDescriptor(size: capacity*MemoryLayout<GPUParticleInstance>.stride,
                usage: [.storageRead,.storageWrite,.transferSource],label: "native-particle-visible"))
            if let visible { device.destroy(visible) }; visible = next; instanceCapacity = capacity
        }
        if batches > batchCapacity {
            let capacity = max(batches,max(batchCapacity*2,64))
            let next = try device.makeBuffer(BufferDescriptor(size: capacity*MemoryLayout<GPUParticleIndirectDrawArgs>.stride,
                usage: [.storageWrite,.indirect,.transferSource],label: "native-particle-indirect"))
            if let indirect { device.destroy(indirect) }; indirect = next; batchCapacity = capacity
        }
    }
}
