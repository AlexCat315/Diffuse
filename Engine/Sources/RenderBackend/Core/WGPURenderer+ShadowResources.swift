import EngineMath
import RHIWGPU
import SceneRuntime
import simd

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

    func writeShadowUniforms(scene: RenderScene, enabled: Bool, settings: RenderShadowSettings) -> ShadowAtlasPlan {
        let plan = makeShadowAtlasPlan(scene: scene, enabled: enabled, settings: settings)
        guard let shadowUniformBuffer else { return plan }
        var uniforms = plan.uniforms
        writeUniform(&uniforms, buffer: shadowUniformBuffer)
        return plan
    }

    func makeShadowAtlasPlan(scene: RenderScene, enabled: Bool, settings: RenderShadowSettings) -> ShadowAtlasPlan {
        let tileSize = RenderShadowSettings.sanitizedMapResolution(settings.mapResolution)
        let capacity = shadowAtlasCapacity(settings: settings)
        let gridDimension = shadowAtlasGridDimension(capacity: capacity)
        let atlasSize = tileSize * gridDimension
        guard enabled,
              settings.enabled,
              settings.maxShadowedDirectionalLights > 0
        else {
            return ShadowAtlasPlan(
                uniforms: .disabled(mapResolution: tileSize),
                lights: [],
                tileSize: tileSize,
                atlasSize: atlasSize,
                gridDimension: gridDimension
            )
        }

        let selectedLights = selectedDirectionalShadowLights(in: scene, settings: settings)
        guard !selectedLights.isEmpty else {
            return ShadowAtlasPlan(
                uniforms: .disabled(mapResolution: tileSize),
                lights: [],
                tileSize: tileSize,
                atlasSize: atlasSize,
                gridDimension: gridDimension
            )
        }
        let sceneBounds = worldBounds(for: scene)
        var lights: [ShadowAtlasLight] = []
        lights.reserveCapacity(selectedLights.count)
        var params = Array(repeating: SIMD4<Float>(settings.depthBias, settings.strength, 0, 0),
                           count: maxShadowedDirectionalLightCount)
        var matrices = Array(repeating: matrix_identity_float4x4,
                             count: maxShadowedDirectionalLightCount)

        for (slot, selected) in selectedLights.enumerated() {
            let tileX = UInt32(slot) % gridDimension
            let tileY = UInt32(slot) / gridDimension
            let matrix = lightViewProjection(for: selected.light, sceneBounds: sceneBounds)
            matrices[slot] = matrix
            let atlasOrigin = SIMD2<Float>(
                Float(tileX * tileSize) / Float(atlasSize),
                Float(tileY * tileSize) / Float(atlasSize)
            )
            params[slot] = SIMD4<Float>(
                settings.depthBias,
                settings.strength,
                atlasOrigin.x,
                atlasOrigin.y
            )
            lights.append(
                ShadowAtlasLight(
                    sceneLightIndex: selected.sceneIndex,
                    slot: slot,
                    tileX: tileX,
                    tileY: tileY,
                    lightViewProjection: matrix
                )
            )
        }

        let uniforms = ShadowUniforms(
            lightViewProjection0: matrices[0],
            lightViewProjection1: matrices[1],
            lightViewProjection2: matrices[2],
            lightViewProjection3: matrices[3],
            params0: params[0],
            params1: params[1],
            params2: params[2],
            params3: params[3],
            atlasParams: SIMD4<Float>(
                1,
                Float(lights.count),
                Float(tileSize),
                Float(atlasSize)
            )
        )
        return ShadowAtlasPlan(
            uniforms: uniforms,
            lights: lights,
            tileSize: tileSize,
            atlasSize: atlasSize,
            gridDimension: gridDimension
        )
    }

    func shadowedDirectionalLightCount(scene: RenderScene, settings: RenderShadowSettings) -> Int {
        guard settings.enabled,
              settings.maxShadowedDirectionalLights > 0
        else { return 0 }
        return selectedDirectionalShadowLights(in: scene, settings: settings).count
    }

    private func selectedDirectionalShadowLights(
        in scene: RenderScene,
        settings: RenderShadowSettings
    ) -> [(sceneIndex: Int, light: RenderLight)] {
        let limit = min(
            shadowAtlasCapacity(settings: settings),
            maxShadowedDirectionalLightCount
        )
        guard limit > 0 else { return [] }
        let candidates = scene.lights.enumerated().compactMap { index, light -> (sceneIndex: Int, light: RenderLight)? in
            guard light.type == .directional && light.intensity > 0 else { return nil }
            return (index, light)
        }
        switch settings.directionalLightSelection {
        case .brightest:
            return candidates
                .sorted { lhs, rhs in
                    if lhs.light.intensity == rhs.light.intensity {
                        return lhs.sceneIndex < rhs.sceneIndex
                    }
                    return lhs.light.intensity > rhs.light.intensity
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    private func lightViewProjection(
        for light: RenderLight,
        sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    ) -> simd_float4x4 {
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
        return projection * view
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

private func shadowAtlasCapacity(settings: RenderShadowSettings) -> Int {
    max(1, min(settings.maxShadowedDirectionalLights, maxShadowedDirectionalLightCount))
}

private func shadowAtlasGridDimension(capacity: Int) -> UInt32 {
    let clamped = max(1, min(capacity, maxShadowedDirectionalLightCount))
    var dimension = 1
    while dimension * dimension < clamped {
        dimension += 1
    }
    return UInt32(dimension)
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
