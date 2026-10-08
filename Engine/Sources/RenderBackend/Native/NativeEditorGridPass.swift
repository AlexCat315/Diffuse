import Foundation
import NativeRHI

/// The editor's existing grid pass, recorded through NativeRHI. The caller owns
/// targets and the frame; default load actions preserve scene color and depth.
public final class NativeEditorGridPass {
    private let device: Device
    private let pipeline: GraphicsPipeline
    private let bindingLayout: BindingLayout
    private let uniformSlot: UInt32

    public init(device: Device, colorFormat: TextureFormat = .bgra8Unorm,
                depthFormat: TextureFormat = .depth32Float) throws {
        self.device = device
        let vertex = try Self.artifact(api: device.backendAPI, stage: .vertex)
        let fragment = try Self.artifact(api: device.backendAPI, stage: .fragment)
        guard let uniform = fragment.interface.bindings.first(where: { $0.name == "grid" }),
              uniform.type == .uniformBuffer, uniform.space == 0,
              fragment.interface.bindings.count == 1 else {
            throw RHIError.layoutMismatch("editor grid expects one uniform block in space0")
        }
        uniformSlot = uniform.slot
        bindingLayout = try device.makeBindingLayout(fragment.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindingLayout]))
        let vertexModule = try device.makeShaderModule(vertex.moduleDescriptor())
        defer { device.destroy(vertexModule) }
        let fragmentModule = try device.makeShaderModule(fragment.moduleDescriptor())
        defer { device.destroy(fragmentModule) }
        var raster = RasterizationState(); raster.cullMode = .none
        let depth = DepthStencilState(depthCompare: .lessOrEqual, depthWriteEnabled: false)
        pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(
            layout: layout, vertex: vertexModule, fragment: fragmentModule,
            colorAttachments: [ColorAttachmentDescriptor(format: colorFormat, blend: .alphaBlend)],
            depthFormat: depthFormat, rasterization: raster, depthStencil: depth, label: "editor-grid"))
    }

    deinit { device.destroy(pipeline) }

    public func encode(packet: RenderPacket, color: RenderColorTarget, depth: RenderDepthTarget,
                       into commands: CommandBuffer) throws {
        let size = packet.drawableSize
        guard size.width > 0, size.height > 0, packet.renderSettings.editorGridSpacing.isFinite else {
            throw RHIError.invalidArgument("grid requires a nonempty viewport and finite spacing")
        }
        let uniforms = EditorGridUniforms.make(camera: packet.scene.camera,
            matrices: RenderCameraMatrices.make(scene: packet.scene, drawableSize: size),
            size: size, spacing: packet.renderSettings.editorGridSpacing)
        let data = withUnsafeBytes(of: uniforms) { Data($0) }
        let upload = try device.uploadTransient(data)
        let bindings = try device.makeBindingSet(layout: bindingLayout, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: uniformSlot, resource: .uniformBuffer(buffer: upload.buffer, offset: upload.offset, size: data.count))
        ]))
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [color], depthTarget: depth)) { pass in
            pass.setPipeline(pipeline)
            pass.setBindingSet(bindings)
            pass.setViewport(Viewport(width: Double(size.width), height: Double(size.height)))
            pass.setScissor(ScissorRect(width: Int(size.width), height: Int(size.height)))
            pass.draw(vertexCount: 3)
        }
    }

    private static func artifact(api: GraphicsAPI, stage: ShaderStage) throws -> ShaderArtifact {
        let target: String
        switch api { case .metal: target = "metal"; case .vulkan: target = "spirv"; case .dx12: target = "dxil" }
        let name = "editor_grid.\(stage.rawValue)"
        guard let url = RenderBackendResourceBundle.bundle.url(forResource: name, withExtension: "json",
            subdirectory: "Shaders/Native/\(target)") else {
            throw RHIError.unsupportedFeature("missing \(target) grid artifact; rebuild native renderer shaders")
        }
        let artifact = try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: url))
        guard artifact.stage == stage else { throw RHIError.layoutMismatch("grid artifact stage mismatch") }
        return artifact
    }
}
