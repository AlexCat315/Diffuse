import Foundation
import NativeRHI

final class NativeUIShaderResources {
    let device: Device
    let vertex: ShaderModule
    let fragment: ShaderModule
    let bindings: BindingLayout
    let layout: PipelineLayout
    let sampler: Sampler

    init(device: Device) throws {
        self.device = device
        let vertexArtifact = try Self.artifact(api: device.backendAPI, stage: .vertex)
        let fragmentArtifact = try Self.artifact(api: device.backendAPI, stage: .fragment)
        vertex = try device.makeShaderModule(vertexArtifact.moduleDescriptor())
        do { fragment = try device.makeShaderModule(fragmentArtifact.moduleDescriptor()) }
        catch { device.destroy(vertex); throw error }
        do {
            bindings = try device.makeBindingLayout(BindingLayoutDescriptor(reflecting: [vertexArtifact, fragmentArtifact]))
            layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindings]))
            var descriptor = SamplerDescriptor(); descriptor.minFilter = .linear; descriptor.magFilter = .linear
            descriptor.mipFilter = .nearest
            descriptor.addressModeU = .clampToEdge; descriptor.addressModeV = .clampToEdge
            sampler = try device.makeSampler(descriptor)
        } catch { device.destroy(vertex); device.destroy(fragment); throw error }
    }

    deinit { device.destroy(vertex); device.destroy(fragment); device.destroy(sampler) }

    private static func artifact(api: GraphicsAPI, stage: ShaderStage) throws -> ShaderArtifact {
        let target: String
        switch api { case .metal: target = "metal"; case .vulkan: target = "spirv"; case .dx12: target = "dxil" }
        guard let url = Bundle.module.url(forResource: "ui.\(stage.rawValue)", withExtension: "json",
            subdirectory: "Shaders/Native/\(target)") else {
            throw RHIError.unsupportedFeature("missing offline \(target) UI shader; rebuild native renderer shaders")
        }
        let artifact = try JSONDecoder().decode(ShaderArtifact.self, from: Data(contentsOf: url))
        guard artifact.stage == stage else { throw RHIError.layoutMismatch("UI artifact stage mismatch") }
        return artifact
    }
}

final class NativeUIPipeline {
    let shaders: NativeUIShaderResources
    let format: TextureFormat
    let samples: Int
    let handle: GraphicsPipeline

    init(shaders: NativeUIShaderResources, format: TextureFormat, samples: Int) throws {
        guard [.rgba8Unorm, .bgra8Unorm, .rgba8UnormSRGB, .bgra8UnormSRGB, .rgba16Float].contains(format) else {
            throw RHIError.unsupportedFeature("unsupported UI color target format")
        }
        self.shaders = shaders; self.format = format; self.samples = samples
        var raster = RasterizationState(); raster.cullMode = .none
        var descriptor = GraphicsPipelineDescriptor(layout: shaders.layout, vertex: shaders.vertex, fragment: shaders.fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: format, blend: .alphaBlend)], depthFormat: nil,
            rasterization: raster, depthStencil: nil, vertexLayout: VertexLayoutDescriptor(attributes: [
                VertexAttribute(location: 0, format: .float2, offset: 0),
                VertexAttribute(location: 1, format: .float2, offset: 8),
                VertexAttribute(location: 2, format: .unorm8x4, offset: 16)
            ], bufferLayouts: [VertexBufferLayout(stride: UIVertex.stride)]), label: "native-ui")
        descriptor.sampleCount = samples
        handle = try shaders.device.makeGraphicsPipeline(descriptor)
    }

    var srgb: Float { format == .rgba8UnormSRGB || format == .bgra8UnormSRGB ? 1 : 0 }
    deinit { shaders.device.destroy(handle) }
}
