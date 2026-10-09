import RHIWGPU

extension WGPURenderer {
    func makeRenderTarget(width: UInt32, height: UInt32, format: GPUTextureFormat) throws -> RenderTextureTarget {
        let texture = try backend.createTexture(
            width: width,
            height: height,
            format: format,
            usage: [.renderAttachment, .textureBinding, .copySrc, .copyDst]
        )
        let view = try texture.createView()
        return RenderTextureTarget(texture: texture, view: view)
    }

    func nextPingPongTarget(after current: RenderTextureTarget) -> RenderTextureTarget? {
        guard let postProcessTargetA, let postProcessTargetB else { return nil }
        return current.texture === postProcessTargetA.texture ? postProcessTargetB : postProcessTargetA
    }

    func writeUniform<T>(_ value: inout T, buffer: GPUBuffer) {
        withUnsafeBytes(of: &value) { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(buffer, data: base, size: raw.count)
            }
        }
    }

    func makeBindGroup(pipeline: GPURenderPipeline, entries: [GPUBindGroupEntry]) throws -> GPUBindGroup {
        let layout = try pipeline.getBindGroupLayout(group: 0)
        return try backend.createBindGroup(layout: layout, entries: entries)
    }
}
