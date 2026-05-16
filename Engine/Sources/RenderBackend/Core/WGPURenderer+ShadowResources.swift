import Foundation
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

    func writeShadowUniforms(
        scene: RenderScene,
        drawableSize: RenderDrawableSize,
        enabled: Bool,
        settings: RenderShadowSettings
    ) -> ShadowAtlasPlan {
        let plan = makeShadowAtlasPlan(
            scene: scene,
            drawableSize: drawableSize,
            enabled: enabled,
            settings: settings
        )
        guard let shadowUniformBuffer else { return plan }
        var uniforms = plan.uniforms
        writeUniform(&uniforms, buffer: shadowUniformBuffer)
        return plan
    }

    func makeShadowAtlasPlan(
        scene: RenderScene,
        drawableSize: RenderDrawableSize,
        enabled: Bool,
        settings: RenderShadowSettings
    ) -> ShadowAtlasPlan {
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
                gridDimension: gridDimension,
                cascadeCount: 0
            )
        }

        let selectedLights = selectedDirectionalShadowLights(in: scene, settings: settings)
        guard !selectedLights.isEmpty else {
            return ShadowAtlasPlan(
                uniforms: .disabled(mapResolution: tileSize),
                lights: [],
                tileSize: tileSize,
                atlasSize: atlasSize,
                gridDimension: gridDimension,
                cascadeCount: 0
            )
        }
        let sceneBounds = worldBounds(for: scene)
        let allocations = directionalShadowAllocations(
            selectedLights: selectedLights,
            settings: settings
        )
        var lights: [ShadowAtlasLight] = []
        lights.reserveCapacity(allocations.reduce(0) { $0 + $1.cascadeCount })
        var params = Array(repeating: SIMD4<Float>(settings.depthBias, settings.strength, 0, 0),
                           count: maxShadowAtlasTileCount)
        var matrices = Array(repeating: matrix_identity_float4x4,
                             count: maxShadowAtlasTileCount)
        let aspect = aspectRatio(for: drawableSize)
        let primaryCascadeCount = allocations.first?.cascadeCount ?? 0
        let cascadeSplits = cascadeSplitDistances(
            camera: scene.camera,
            count: max(primaryCascadeCount, 1),
            lambda: settings.directionalCascadeSplitLambda
        )
        var packedCascadeSplits = SIMD4<Float>(repeating: scene.camera.far)
        for index in 0..<min(cascadeSplits.count, maxShadowAtlasTileCount) {
            packedCascadeSplits[index] = cascadeSplits[index]
        }
        let cameraForward = normalized(scene.camera.target - scene.camera.eye, fallback: SIMD3<Float>(0, 0, -1))

        var slot = 0
        for allocation in allocations {
            guard slot < capacity else { break }
            if allocation.cascadeCount > 1 {
                for cascadeIndex in 0..<allocation.cascadeCount {
                    guard slot < capacity else { break }
                    let tileX = UInt32(slot) % gridDimension
                    let tileY = UInt32(slot) / gridDimension
                    let splitNear = cascadeIndex == 0 ? max(scene.camera.near, 0.01) : cascadeSplits[cascadeIndex - 1]
                    let splitFar = cascadeSplits[cascadeIndex]
                    let frustumCorners = cameraFrustumCorners(
                        camera: scene.camera,
                        aspect: aspect,
                        nearDistance: splitNear,
                        farDistance: splitFar
                    )
                    let matrix = lightViewProjection(
                        for: allocation.light,
                        fitting: frustumCorners,
                        tileSize: tileSize
                    )
                    packShadowTile(
                        slot: slot,
                        tileX: tileX,
                        tileY: tileY,
                        tileSize: tileSize,
                        atlasSize: atlasSize,
                        matrix: matrix,
                        params: &params,
                        matrices: &matrices,
                        settings: settings
                    )
                    lights.append(
                        ShadowAtlasLight(
                            sceneLightIndex: allocation.sceneIndex,
                            slot: slot,
                            cascadeIndex: cascadeIndex,
                            tileX: tileX,
                            tileY: tileY,
                            lightViewProjection: matrix
                        )
                    )
                    slot += 1
                }
            } else {
                let tileX = UInt32(slot) % gridDimension
                let tileY = UInt32(slot) / gridDimension
                let matrix = lightViewProjection(for: allocation.light, sceneBounds: sceneBounds)
                packShadowTile(
                    slot: slot,
                    tileX: tileX,
                    tileY: tileY,
                    tileSize: tileSize,
                    atlasSize: atlasSize,
                    matrix: matrix,
                    params: &params,
                    matrices: &matrices,
                    settings: settings
                )
                lights.append(
                    ShadowAtlasLight(
                        sceneLightIndex: allocation.sceneIndex,
                        slot: slot,
                        cascadeIndex: 0,
                        tileX: tileX,
                        tileY: tileY,
                        lightViewProjection: matrix
                    )
                )
                slot += 1
            }
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
            ),
            cascadeSplits: packedCascadeSplits,
            cameraPositionAndPadding: SIMD4<Float>(scene.camera.eye, 0),
            cameraForwardAndPadding: SIMD4<Float>(cameraForward, 0)
        )
        return ShadowAtlasPlan(
            uniforms: uniforms,
            lights: lights,
            tileSize: tileSize,
            atlasSize: atlasSize,
            gridDimension: gridDimension,
            cascadeCount: primaryCascadeCount
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
            settings.maxShadowedDirectionalLights,
            maxShadowAtlasTileCount
        )
        guard limit > 0 else { return [] }
        let candidates = scene.lights.enumerated().compactMap { index, light -> (sceneIndex: Int, light: RenderLight)? in
            guard index < maxSceneLightUniformCount,
                  light.type == .directional,
                  light.intensity > 0
            else { return nil }
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

    private func directionalShadowAllocations(
        selectedLights: [(sceneIndex: Int, light: RenderLight)],
        settings: RenderShadowSettings
    ) -> [DirectionalShadowAllocation] {
        var remainingTiles = shadowAtlasCapacity(settings: settings)
        var allocations: [DirectionalShadowAllocation] = []
        allocations.reserveCapacity(selectedLights.count)
        for (index, selected) in selectedLights.enumerated() {
            guard remainingTiles > 0 else { break }
            let cascadeCount: Int
            if index == 0 {
                let remainingLights = selectedLights.count - 1
                let availableForPrimary = max(1, remainingTiles - remainingLights)
                cascadeCount = min(settings.directionalCascadeCount, availableForPrimary)
            } else {
                cascadeCount = 1
            }
            allocations.append(
                DirectionalShadowAllocation(
                    sceneIndex: selected.sceneIndex,
                    light: selected.light,
                    cascadeCount: cascadeCount
                )
            )
            remainingTiles -= cascadeCount
        }
        return allocations
    }

    private func packShadowTile(
        slot: Int,
        tileX: UInt32,
        tileY: UInt32,
        tileSize: UInt32,
        atlasSize: UInt32,
        matrix: simd_float4x4,
        params: inout [SIMD4<Float>],
        matrices: inout [simd_float4x4],
        settings: RenderShadowSettings
    ) {
        guard matrices.indices.contains(slot),
              params.indices.contains(slot)
        else { return }
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

    private func lightViewProjection(
        for light: RenderLight,
        fitting worldCorners: [SIMD3<Float>],
        tileSize: UInt32
    ) -> simd_float4x4 {
        let cornerBounds = bounds(of: worldCorners)
        let center = (cornerBounds.min + cornerBounds.max) * 0.5
        let diagonal = cornerBounds.max - cornerBounds.min
        let radius = max(simd_length(diagonal) * 0.5, 1.0)
        let lightDirection = normalized(light.direction, fallback: SIMD3<Float>(0, -1, 0))
        let eye = center - lightDirection * radius * 2.5
        let up = abs(simd_dot(lightDirection, SIMD3<Float>(0, 1, 0))) > 0.92
            ? SIMD3<Float>(0, 0, 1)
            : SIMD3<Float>(0, 1, 0)
        let view = CameraMatrices.lookAtRH(eye: eye, target: center, up: up)
        let lightSpaceCorners = worldCorners.map {
            transformPoint($0, by: view)
        }
        let lightSpaceBounds = bounds(of: lightSpaceCorners)
        let margin = max(0.25, radius * 0.05)
        let width = max(lightSpaceBounds.max.x - lightSpaceBounds.min.x + margin * 2, 0.5)
        let height = max(lightSpaceBounds.max.y - lightSpaceBounds.min.y + margin * 2, 0.5)
        let centerX = (lightSpaceBounds.min.x + lightSpaceBounds.max.x) * 0.5
        let centerY = (lightSpaceBounds.min.y + lightSpaceBounds.max.y) * 0.5
        let texelX = width / Float(max(tileSize, 1))
        let texelY = height / Float(max(tileSize, 1))
        let snappedCenterX = floor(centerX / texelX) * texelX
        let snappedCenterY = floor(centerY / texelY) * texelY
        let left = snappedCenterX - width * 0.5
        let right = snappedCenterX + width * 0.5
        let bottom = snappedCenterY - height * 0.5
        let top = snappedCenterY + height * 0.5
        let depthMargin = max(0.5, radius * 0.35)
        let near = max(0.05, -lightSpaceBounds.max.z - depthMargin)
        let far = max(near + 0.5, -lightSpaceBounds.min.z + depthMargin)
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

private struct DirectionalShadowAllocation {
    let sceneIndex: Int
    let light: RenderLight
    let cascadeCount: Int
}

private func aspectRatio(for drawableSize: RenderDrawableSize) -> Float {
    Float(max(drawableSize.width, 1)) / Float(max(drawableSize.height, 1))
}

private func cascadeSplitDistances(
    camera: RenderCamera,
    count: Int,
    lambda: Float
) -> [Float] {
    let cascadeCount = min(max(count, 1), maxShadowAtlasTileCount)
    let near = max(camera.near, 0.01)
    let far = max(camera.far, near + 0.1)
    guard cascadeCount > 1 else { return [far] }
    return (1...cascadeCount).map { index in
        let p = Float(index) / Float(cascadeCount)
        let logarithmic = near * pow(far / near, p)
        let uniform = near + (far - near) * p
        return lambda * logarithmic + (1 - lambda) * uniform
    }
}

private func cameraFrustumCorners(
    camera: RenderCamera,
    aspect: Float,
    nearDistance: Float,
    farDistance: Float
) -> [SIMD3<Float>] {
    let forward = normalized(camera.target - camera.eye, fallback: SIMD3<Float>(0, 0, -1))
    let side = normalized(simd_cross(forward, camera.up), fallback: SIMD3<Float>(1, 0, 0))
    let up = normalized(simd_cross(side, forward), fallback: SIMD3<Float>(0, 1, 0))
    let tanHalfFov = tan(max(camera.fovYRadians, 0.001) * 0.5)

    func corners(at distance: Float) -> [SIMD3<Float>] {
        let height = max(distance, 0.001) * tanHalfFov
        let width = height * max(aspect, Float.ulpOfOne)
        let center = camera.eye + forward * distance
        return [
            center - side * width - up * height,
            center + side * width - up * height,
            center - side * width + up * height,
            center + side * width + up * height,
        ]
    }

    return corners(at: nearDistance) + corners(at: farDistance)
}

private func normalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(value)
    guard lengthSquared > Float.ulpOfOne else { return fallback }
    return value / sqrt(lengthSquared)
}

private func shadowAtlasCapacity(settings: RenderShadowSettings) -> Int {
    guard settings.maxShadowedDirectionalLights > 0 else { return 1 }
    let requestedTiles = settings.maxShadowedDirectionalLights
        + max(0, settings.directionalCascadeCount - 1)
    return max(1, min(requestedTiles, maxShadowAtlasTileCount))
}

private func shadowAtlasGridDimension(capacity: Int) -> UInt32 {
    let clamped = max(1, min(capacity, maxShadowAtlasTileCount))
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
