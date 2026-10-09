/// Mesh pipelines share attachment and rasterization semantics with graphics
/// pipelines, but never contain a vertex layout or vertex shader.
public struct MeshPipelineDescriptor: Sendable {
    public var layout: PipelineLayout
    public var mesh: ShaderModule
    public var task: ShaderModule?
    public var fragment: ShaderModule?
    public var colorAttachments: [ColorAttachmentDescriptor] = []
    public var depthFormat: TextureFormat?
    public var rasterization = RasterizationState()
    public var depthStencil: DepthStencilState?
    public var label: String?

    public init(layout: PipelineLayout, mesh: ShaderModule) {
        self.layout = layout
        self.mesh = mesh
    }
}

public struct MeshPipeline: RHIHandle {
    public let id: UInt32
    public init(id: UInt32) { self.id = id }
}
