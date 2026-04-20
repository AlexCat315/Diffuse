import CWGPUBridge

public final class GPUShaderModule {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_shader_module(handle)
    }
}

public struct GPURenderPipelineDescriptor {
    public var shaderModule: GPUShaderModule
    public var vertexEntryPoint: String
    public var fragmentEntryPoint: String
    public var colorFormat: GPUTextureFormat
    public var topology: GPUPrimitiveTopology
    public var cullMode: GPUCullMode
    public var vertexBuffers: [GPUVertexBufferLayout]

    public init(shaderModule: GPUShaderModule,
                vertexEntryPoint: String = "vs_main",
                fragmentEntryPoint: String = "fs_main",
                colorFormat: GPUTextureFormat = .bgra8Unorm,
                topology: GPUPrimitiveTopology = .triangleList,
                cullMode: GPUCullMode = .none,
                vertexBuffers: [GPUVertexBufferLayout] = []) {
        self.shaderModule = shaderModule
        self.vertexEntryPoint = vertexEntryPoint
        self.fragmentEntryPoint = fragmentEntryPoint
        self.colorFormat = colorFormat
        self.topology = topology
        self.cullMode = cullMode
        self.vertexBuffers = vertexBuffers
    }
}

public final class GPURenderPipeline {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_render_pipeline(handle)
    }
}
