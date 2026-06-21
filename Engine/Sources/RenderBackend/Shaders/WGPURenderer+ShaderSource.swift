extension WGPURenderer {
    static func loadShaderSource(named name: String) throws -> String {
        try ShaderCatalog().loadWGSLRenderModule(named: name)
    }

    static func loadComputeShaderSource(named name: String) throws -> String {
        try ShaderCatalog().loadWGSLComputeModule(named: name)
    }
}
