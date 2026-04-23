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

extension GPUShaderModule: @unchecked Sendable {}

public struct GPURenderPipelineDescriptor: @unchecked Sendable {
    public var shaderModule: GPUShaderModule
    public var pipelineLayout: GPUPipelineLayout?
    public var vertexEntryPoint: String
    public var fragmentEntryPoint: String
    public var colorFormat: GPUTextureFormat
    public var topology: GPUPrimitiveTopology
    public var frontFace: GPUFrontFace
    public var cullMode: GPUCullMode
    public var vertexBuffers: [GPUVertexBufferLayout]
    public var blend: GPUBlendState?
    public var depthStencil: GPUDepthStencilPipelineState?

    public init(shaderModule: GPUShaderModule,
                pipelineLayout: GPUPipelineLayout? = nil,
                vertexEntryPoint: String = "vs_main",
                fragmentEntryPoint: String = "fs_main",
                colorFormat: GPUTextureFormat = .bgra8Unorm,
                topology: GPUPrimitiveTopology = .triangleList,
                frontFace: GPUFrontFace = .ccw,
                cullMode: GPUCullMode = .none,
                vertexBuffers: [GPUVertexBufferLayout] = [],
                blend: GPUBlendState? = nil,
                depthStencil: GPUDepthStencilPipelineState? = nil) {
        self.shaderModule = shaderModule
        self.pipelineLayout = pipelineLayout
        self.vertexEntryPoint = vertexEntryPoint
        self.fragmentEntryPoint = fragmentEntryPoint
        self.colorFormat = colorFormat
        self.topology = topology
        self.frontFace = frontFace
        self.cullMode = cullMode
        self.vertexBuffers = vertexBuffers
        self.blend = blend
        self.depthStencil = depthStencil
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

    public func getBindGroupLayout(group: UInt32) throws -> GPUBindGroupLayout {
        var ptr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_render_pipeline_get_bind_group_layout(handle, group, &ptr)
        guard ok == 1, let ptr else {
            throw WGPUBackendError.initFailed(WGPUBackend.lastError())
        }
        return GPUBindGroupLayout(handle: ptr)
    }
}

extension GPURenderPipeline: @unchecked Sendable {}
