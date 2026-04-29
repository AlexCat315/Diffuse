import RHIWGPU

extension WGPURenderer {
    func ensureSkyboxPipeline() throws {
        guard skyboxPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "skybox"), label: "skybox")
        skyboxPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none,
                depthStencil: GPUDepthStencilPipelineState(
                    format: depthFormat,
                    depthWriteEnabled: false,
                    depthCompare: .lessEqual
                )
            )
        )
    }

    func ensureTonemapPipeline() throws {
        guard tonemapPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "tonemap"), label: "tonemap")
        tonemapPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: format,
                cullMode: .none
            )
        )
    }

    func ensureBloomPipeline() throws {
        guard bloomPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "bloom"), label: "bloom")
        bloomPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    func ensureInkPaperPostPipeline() throws {
        guard inkPaperPostPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "ink_paper_post"), label: "ink_paper_post")
        inkPaperPostPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    func ensureFXAAPipeline() throws {
        guard fxaaPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "fxaa"), label: "fxaa")
        fxaaPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: format,
                cullMode: .none
            )
        )
    }

    func ensureSSRPipeline() throws {
        guard ssrPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "ssr"), label: "ssr")
        ssrPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    func ensureTAAPipeline() throws {
        guard taaPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "taa"), label: "taa")
        taaPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    func ensureSSAOPipeline() throws {
        guard ssaoPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "ssao"), label: "ssao")
        ssaoPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }
}
