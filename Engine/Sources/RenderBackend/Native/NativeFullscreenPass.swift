import NativeRHI

/// One immutable full-screen pipeline; callers provide frame-owned bindings.
final class NativeFullscreenPass {
    private let device: Device
    private let bindings: BindingLayout
    private let pipeline: GraphicsPipeline
    init(device: Device, shader: String, colorFormat: TextureFormat, depth: DepthStencilState? = nil) throws {
        self.device = device
        let vs = try NativeShaderLibrary.artifact(name: shader, api: device.backendAPI, stage: .vertex)
        let fs = try NativeShaderLibrary.artifact(name: shader, api: device.backendAPI, stage: .fragment)
        bindings = try device.makeBindingLayout(NativeShaderLibrary.layout(artifacts: [vs,fs]))
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindings]))
        let vertex = try device.makeShaderModule(vs.moduleDescriptor()); defer { device.destroy(vertex) }
        let fragment = try device.makeShaderModule(fs.moduleDescriptor()); defer { device.destroy(fragment) }
        pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: layout, vertex: vertex, fragment: fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: colorFormat)], depthFormat: depth == nil ? nil : .depth32Float,
            rasterization: RasterizationState(cullMode: .none), depthStencil: depth, label: "native-\(shader)"))
    }
    deinit { device.destroy(pipeline) }
    func encode(size: RenderDrawableSize, color: RenderColorTarget, depth: RenderDepthTarget? = nil,
                entries: [BindingSetEntry], into commands: CommandBuffer) throws {
        let set = try device.makeBindingSet(layout: bindings, descriptor: BindingSetDescriptor(entries: entries))
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [color], depthTarget: depth)) { pass in
            pass.setPipeline(pipeline); pass.setBindingSet(set)
            pass.setViewport(Viewport(width: Double(size.width), height: Double(size.height)))
            pass.setScissor(ScissorRect(width: Int(size.width), height: Int(size.height)))
            pass.draw(vertexCount: 3)
        }
    }
}
