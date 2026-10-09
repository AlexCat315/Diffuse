import Foundation
import EngineMath
import RHIWGPU
import SceneRuntime
import SIMDCompat

extension WGPURenderer {
    func ensureShadowResources(settings: RenderShadowSettings) throws {
        guard backend.rawDevice != nil else { return }
        let tileSize = RenderShadowSettings.sanitizedMapResolution(settings.mapResolution)
        let capacity = shadowAtlasCapacity(settings: settings)
        let gridDimension = shadowAtlasGridDimension(capacity: capacity)
        let atlasSize = tileSize * gridDimension
        if shadowUniformBuffer == nil {
            shadowUniformBuffer = try backend.createBuffer(
                size: UInt64(MemoryLayout<ShadowUniforms>.stride),
                usage: [.uniform, .copyDst]
            )
        }
        while shadowRenderUniformBuffers.count < capacity {
            shadowRenderUniformBuffers.append(
                try backend.createBuffer(
                    size: UInt64(MemoryLayout<ShadowRenderUniforms>.stride),
                    usage: [.uniform, .copyDst]
                )
            )
        }
        if shadowSampler == nil {
            shadowSampler = try backend.createSampler(
                desc: GPUSamplerDescriptor(
                    addressModeU: .clampToEdge,
                    addressModeV: .clampToEdge,
                    magFilter: .linear,
                    minFilter: .linear,
                    mipmapFilter: .nearest
                )
            )
        }
        if let shadowMapTarget,
           shadowMapTarget.tileSize == tileSize,
           shadowMapTarget.gridDimension == gridDimension,
           shadowMapTarget.capacity == capacity,
           shadowMapTarget.size == atlasSize {
            return
        }

        let color = try backend.createTexture(
            width: atlasSize,
            height: atlasSize,
            format: hdrFormat,
            usage: [.renderAttachment, .textureBinding, .copySrc]
        )
        let depth = try backend.createTexture(
            width: atlasSize,
            height: atlasSize,
            format: depthFormat,
            usage: [.renderAttachment]
        )
        shadowMapTarget = ShadowMapTarget(
            colorTexture: color,
            colorView: try color.createView(),
            depthTexture: depth,
            depthView: try depth.createView(),
            tileSize: tileSize,
            gridDimension: gridDimension,
            capacity: capacity,
            size: atlasSize
        )
        shadowResourceGeneration &+= 1
    }

    func writeShadowUniforms(
        scene: RenderScene,
        drawableSize: RenderDrawableSize,
        enabled: Bool,
        settings: RenderShadowSettings,
        palettes: JointPaletteMap = JointPaletteMap()
    ) -> ShadowAtlasPlan {
        let plan = makeShadowAtlasPlan(
            scene: scene,
            drawableSize: drawableSize,
            enabled: enabled,
            settings: settings,
            palettes: palettes
        )
        guard let shadowUniformBuffer else { return plan }
        var uniforms = plan.uniforms
        writeUniform(&uniforms, buffer: shadowUniformBuffer)
        return plan
    }

    func makeShadowAtlasPlan(scene: RenderScene, drawableSize: RenderDrawableSize,
                             enabled: Bool, settings: RenderShadowSettings, palettes: JointPaletteMap = JointPaletteMap()) -> ShadowAtlasPlan {
        ShadowAtlasPlanner.makeShadowAtlasPlan(scene: scene, drawableSize: drawableSize,
            enabled: enabled, settings: settings, palettes: palettes, meshBounds: { MeshBoundsRegistry.shared.bounds(for: $0) })
    }
    func shadowedDirectionalLightCount(scene: RenderScene, settings: RenderShadowSettings) -> Int {
        ShadowAtlasPlanner.shadowedDirectionalLightCount(scene: scene, settings: settings)
    }
}
