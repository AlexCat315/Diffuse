import Foundation
import RHIWGPU
import SceneRuntime
import SIMDCompat

struct EditorGridUniforms {
    var inverseViewProjection: simd_float4x4
    var viewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    /// Used viewport dimensions, minor spacing, distance fade limit.
    var viewport: SIMD4<Float>
}

extension WGPURenderer {
    func ensureEditorGridPipeline(hdr: Bool) throws -> GPURenderPipeline {
        if hdr, let editorGridPipelineHDR { return editorGridPipelineHDR }
        if !hdr, let editorGridPipelineLDR { return editorGridPipelineLDR }
        let module = try backend.createShaderModule(
            wgsl: try Self.loadShaderSource(named: "editor_grid"), label: "editor_grid"
        )
        let pipeline = try backend.createRenderPipeline(desc: GPURenderPipelineDescriptor(
            shaderModule: module,
            colorFormat: hdr ? hdrFormat : format,
            blend: .alphaBlending,
            depthStencil: GPUDepthStencilPipelineState(
                format: depthFormat, depthWriteEnabled: false, depthCompare: .lessEqual
            )
        ))
        if hdr { editorGridPipelineHDR = pipeline }
        else { editorGridPipelineLDR = pipeline }
        return pipeline
    }

    func encodeEditorGridPass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        camera: RenderCamera,
        viewProjection: simd_float4x4,
        drawableSize: RenderDrawableSize,
        hdr: Bool
    ) throws {
        let pipeline = try ensureEditorGridPipeline(hdr: hdr)
        if editorGridUniformBuffer == nil {
            editorGridUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
        }
        guard let editorGridUniformBuffer else { return }
        let height = abs(camera.eye.y)
        let spacing = pow(Float(10), floor(log10(max(height * 0.1, 1))))
        var uniforms = EditorGridUniforms(
            inverseViewProjection: simd_inverse(viewProjection),
            viewProjection: viewProjection,
            cameraPosition: SIMD4<Float>(camera.eye, 1),
            viewport: SIMD4<Float>(Float(max(drawableSize.width, 1)),
                                   Float(max(drawableSize.height, 1)),
                                   spacing, max(100, height * 40))
        )
        writeUniform(&uniforms, buffer: editorGridUniformBuffer)
        let bindGroup = try makeBindGroup(pipeline: pipeline, entries: [
            GPUBindGroupEntry(binding: 0, buffer: editorGridUniformBuffer,
                              offset: 0, size: UInt64(MemoryLayout<EditorGridUniforms>.stride))
        ])
        let pass = try encoder.beginRenderPass(
            colorView: colorView, loadOp: .load, storeOp: .store,
            depthView: depthView, depthLoadOp: .load, depthStoreOp: .store
        )
        applyUsedRegion(pass)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }
}
