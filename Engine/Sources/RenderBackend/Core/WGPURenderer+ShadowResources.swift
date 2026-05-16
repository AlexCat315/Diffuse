import EngineMath
import RHIWGPU
import SceneRuntime
import simd

extension WGPURenderer {
    func ensureShadowResources() throws {
        guard backend.rawDevice != nil else { return }
        if shadowUniformBuffer == nil {
            shadowUniformBuffer = try backend.createBuffer(
                size: UInt64(MemoryLayout<ShadowUniforms>.stride),
                usage: [.uniform, .copyDst]
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
        if shadowMapTarget != nil { return }

        let color = try backend.createTexture(
            width: shadowMapResolution,
            height: shadowMapResolution,
            format: hdrFormat,
            usage: [.renderAttachment, .textureBinding, .copySrc]
        )
        let depth = try backend.createTexture(
            width: shadowMapResolution,
            height: shadowMapResolution,
            format: depthFormat,
            usage: [.renderAttachment]
        )
        shadowMapTarget = ShadowMapTarget(
            colorTexture: color,
            colorView: try color.createView(),
            depthTexture: depth,
            depthView: try depth.createView(),
            size: shadowMapResolution
        )
    }

    func writeShadowUniforms(scene: RenderScene, enabled: Bool) -> ShadowUniforms {
        guard let shadowUniformBuffer else { return .disabled }
        var uniforms = makeShadowUniforms(scene: scene, enabled: enabled)
        writeUniform(&uniforms, buffer: shadowUniformBuffer)
        return uniforms
    }

    func makeShadowUniforms(scene: RenderScene, enabled: Bool) -> ShadowUniforms {
        guard enabled,
              let light = primaryDirectionalShadowLight(in: scene)
        else {
            return .disabled
        }

        let sceneBounds = worldBounds(for: scene)
        let center = (sceneBounds.min + sceneBounds.max) * 0.5
        let diagonal = sceneBounds.max - sceneBounds.min
        let radius = max(simd_length(diagonal) * 0.5, 1.0)
        let lightDirection = normalized(light.direction, fallback: SIMD3<Float>(0, -1, 0))
        let eye = center - lightDirection * radius * 2.5
        let up = abs(simd_dot(lightDirection, SIMD3<Float>(0, 1, 0))) > 0.92
            ? SIMD3<Float>(0, 0, 1)
            : SIMD3<Float>(0, 1, 0)
        let view = CameraMatrices.lookAtRH(eye: eye, target: center, up: up)

        let lightSpaceCorners = boundsCorners(min: sceneBounds.min, max: sceneBounds.max).map {
            transformPoint($0, by: view)
        }
        let lightSpaceBounds = bounds(of: lightSpaceCorners)
        let margin = max(0.5, radius * 0.20)
        let left = lightSpaceBounds.min.x - margin
        let right = lightSpaceBounds.max.x + margin
        let bottom = lightSpaceBounds.min.y - margin
        let top = lightSpaceBounds.max.y + margin
        let near = max(0.05, -lightSpaceBounds.max.z - margin)
        let far = max(near + 0.5, -lightSpaceBounds.min.z + margin)
        let projection = orthographicRH_ZO(
            left: left,
            right: right,
            bottom: bottom,
            top: top,
            near: near,
            far: far
        )

        return ShadowUniforms(
            lightViewProjection: projection * view,
            params: SIMD4<Float>(
                1,
                0.006,
                0.62,
                Float(shadowMapResolution)
            )
        )
    }

    private func primaryDirectionalShadowLight(in scene: RenderScene) -> RenderLight? {
        scene.lights.first { light in
            light.type == .directional && light.intensity > 0
        }
    }

    private func worldBounds(for scene: RenderScene) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !scene.instances.isEmpty else {
            let center = scene.camera.target
            let extent = SIMD3<Float>(repeating: 2)
            return (center - extent, center + extent)
        }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(scene.instances.count * 8)
        for instance in scene.instances {
            let localBounds = MeshBoundsRegistry.shared.bounds(for: instance.meshIndex)
                ?? (SIMD3<Float>(repeating: -0.5), SIMD3<Float>(repeating: 0.5))
            for corner in boundsCorners(min: localBounds.min, max: localBounds.max) {
                points.append(transformPoint(corner, by: instance.transform))
            }
        }
        return bounds(of: points)
    }
}

private func normalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(value)
    guard lengthSquared > Float.ulpOfOne else { return fallback }
    return value / sqrt(lengthSquared)
}

private func transformPoint(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
    let transformed = matrix * SIMD4<Float>(point, 1)
    let w = abs(transformed.w) > Float.ulpOfOne ? transformed.w : 1
    return SIMD3<Float>(transformed.x, transformed.y, transformed.z) / w
}

private func boundsCorners(min: SIMD3<Float>, max: SIMD3<Float>) -> [SIMD3<Float>] {
    [
        SIMD3<Float>(min.x, min.y, min.z),
        SIMD3<Float>(max.x, min.y, min.z),
        SIMD3<Float>(min.x, max.y, min.z),
        SIMD3<Float>(max.x, max.y, min.z),
        SIMD3<Float>(min.x, min.y, max.z),
        SIMD3<Float>(max.x, min.y, max.z),
        SIMD3<Float>(min.x, max.y, max.z),
        SIMD3<Float>(max.x, max.y, max.z),
    ]
}

private func bounds(of points: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
    guard var minPoint = points.first else {
        return (SIMD3<Float>(repeating: -1), SIMD3<Float>(repeating: 1))
    }
    var maxPoint = minPoint
    for point in points.dropFirst() {
        minPoint = simd.min(minPoint, point)
        maxPoint = simd.max(maxPoint, point)
    }
    return (minPoint, maxPoint)
}

private func orthographicRH_ZO(
    left: Float,
    right: Float,
    bottom: Float,
    top: Float,
    near: Float,
    far: Float
) -> simd_float4x4 {
    let width = max(right - left, Float.ulpOfOne)
    let height = max(top - bottom, Float.ulpOfOne)
    let depth = max(far - near, Float.ulpOfOne)
    return simd_float4x4(rows: [
        SIMD4<Float>(2 / width, 0, 0, -(right + left) / width),
        SIMD4<Float>(0, 2 / height, 0, -(top + bottom) / height),
        SIMD4<Float>(0, 0, -1 / depth, -near / depth),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
