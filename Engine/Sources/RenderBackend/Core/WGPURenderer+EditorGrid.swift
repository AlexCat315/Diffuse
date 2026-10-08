import Foundation
import RHIWGPU
import SceneRuntime
import SIMDCompat

/// Axis-aligned reference plane facing an orthographic editor view.
public struct EditorGridPlane {
    public let u: SIMD3<Float>
    public let v: SIMD3<Float>
    public let uAxis: Float
    public let vAxis: Float
    public var normal: SIMD3<Float> { simd_cross(u, v) }

    public static func make(camera: RenderCamera) -> EditorGridPlane {
        let forward = simd_abs(camera.target - camera.eye)
        if camera.projection == .orthographic {
            if forward.z >= forward.x, forward.z >= forward.y {
                return EditorGridPlane(u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), uAxis: 0, vAxis: 1)
            }
            if forward.x >= forward.y {
                return EditorGridPlane(u: SIMD3<Float>(0, 0, 1), v: SIMD3<Float>(0, 1, 0), uAxis: 2, vAxis: 1)
            }
        }
        return EditorGridPlane(u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 0, 1), uAxis: 0, vAxis: 2)
    }
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
        cameraMatrices: RenderCameraMatrices,
        drawableSize: RenderDrawableSize,
        hdr: Bool
    ) throws {
        let pipeline = try ensureEditorGridPipeline(hdr: hdr)
        if editorGridUniformBuffer == nil {
            editorGridUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
        }
        guard let editorGridUniformBuffer else { return }
        var uniforms = EditorGridUniforms.make(camera: camera, matrices: cameraMatrices,
            size: drawableSize, spacing: activeRenderSettings.editorGridSpacing)
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
