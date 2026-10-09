#if os(macOS)
import Metal

/// State belongs to one render encoder. Metal keeps independent buffer,
/// texture and sampler index spaces for each shader stage.
final class MetalRenderBindings {
    private struct BufferValue {
        let resource: MTLBuffer
        let offset: Int
    }
    private var buffers = [BufferValue?](repeating: nil, count: 128)
    private var textures = [MTLTexture?](repeating: nil, count: 128)
    private var samplers = [MTLSamplerState?](repeating: nil, count: 128)

    func bufferChanged(_ resource: MTLBuffer, offset: Int, slot: UInt32, stage: ShaderStage) -> Bool {
        guard let index = Self.index(slot, stage) else { return true }
        if let old = buffers[index], old.resource === resource, old.offset == offset { return false }
        buffers[index] = BufferValue(resource: resource, offset: offset)
        return true
    }
    func textureChanged(_ resource: MTLTexture, slot: UInt32, stage: ShaderStage) -> Bool {
        guard let index = Self.index(slot, stage) else { return true }
        if textures[index] === resource { return false }
        textures[index] = resource
        return true
    }
    func samplerChanged(_ resource: MTLSamplerState, slot: UInt32, stage: ShaderStage) -> Bool {
        guard let index = Self.index(slot, stage) else { return true }
        if samplers[index] === resource { return false }
        samplers[index] = resource
        return true
    }
    func invalidateBuffer(slot: UInt32, stage: ShaderStage) {
        if let index = Self.index(slot, stage) { buffers[index] = nil }
    }
    private static func index(_ slot: UInt32, _ stage: ShaderStage) -> Int? {
        // Cache the common index range without restricting higher texture
        // slots. Uncached slots keep the existing encoder path.
        guard slot < 32 else { return nil }
        let group: Int
        switch stage { case .vertex: group = 0; case .fragment: group = 1
        case .task: group = 2; case .mesh: group = 3; case .compute: return nil }
        return group * 32 + Int(slot)
    }
}
#endif
