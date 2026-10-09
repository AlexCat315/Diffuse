import CWGPUBridge

public struct GPUSamplerDescriptor: Sendable {
    public var addressModeU: GPUAddressMode
    public var addressModeV: GPUAddressMode
    public var magFilter: GPUFilterMode
    public var minFilter: GPUFilterMode
    public var mipmapFilter: GPUFilterMode

    public init(addressModeU: GPUAddressMode = .clampToEdge,
                addressModeV: GPUAddressMode = .clampToEdge,
                magFilter: GPUFilterMode = .linear,
                minFilter: GPUFilterMode = .linear,
                mipmapFilter: GPUFilterMode = .nearest) {
        self.addressModeU = addressModeU
        self.addressModeV = addressModeV
        self.magFilter = magFilter
        self.minFilter = minFilter
        self.mipmapFilter = mipmapFilter
    }
}

public final class GPUSampler {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_sampler(handle)
    }
}
