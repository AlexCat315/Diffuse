import Foundation
import RHIWGPU
import SceneRuntime
import Testing
import SIMDCompat
@testable import RenderBackend

private let gpuSmokeEnabled = ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] == "1"

@Suite("RenderBackendGPUSmoke", .serialized)
struct RenderBackendGPUSmokeTests {
    @Test("renders the scene contract into a readable WGPU framebuffer",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU smoke test"))
    func rendersSceneContractIntoFramebuffer() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        let packet = RenderPacket(
            frameIndex: 0,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: width, height: height),
            scene: Self.makeSmokeScene(),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 0
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.viewportResolve))
        #expect(stats.drawCallCount == 2)
        #expect(stats.passDrawCallCounts[.depthPrepass] == 1)
        #expect(stats.passDrawCallCounts[.basePass] == 1)

        let viewport = renderer.currentViewportSurfaceState()
        #expect(viewport.isValid)
        #expect(viewport.width == width)
        #expect(viewport.height == height)

        guard let texture = renderer.offscreenColorTexture else {
            Issue.record("expected renderer to retain an offscreen color texture")
            return
        }

        let pixels = try readbackBGRA8(
            texture: texture,
            width: width,
            height: height,
            backend: backend
        )
        try writeDebugPPMIfRequested(pixels: pixels, width: width, height: height)

        let background = BGRAPixel(
            r: UInt8(0.05 * 255.0),
            g: UInt8(0.06 * 255.0),
            b: UInt8(0.08 * 255.0),
            a: 255
        )
        let center = pixels[Int(height / 2) * Int(width) + Int(width / 2)]
        #expect(center.distance(from: background) > 48)

        let coveredPixels = pixels.count { pixel in
            pixel.a > 0 && pixel.distance(from: background) > 48
        }
        #expect(coveredPixels > Int(width * height) / 32)
    }

    @Test("stylized outline pass compiles and renders through the HDR viewport path",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU stylized outline smoke test"))
    func stylizedOutlinePassCompilesAndRenders() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64
        let pixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: Self.makeSmokeScene(),
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true,
                enableStylizedCharacterShading: true
            ),
            frameIndex: 2,
            width: width,
            height: height
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.depthPrepass))
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.outline))
        #expect(stats.activePasses.contains(.inkPaperPost))
        #expect(stats.activePasses.contains(.viewportResolve))
        #expect(stats.passDrawCallCounts[.depthPrepass] == 1)
        #expect(stats.passDrawCallCounts[.basePass] == 1)
        #expect(stats.passDrawCallCounts[.outline] == 1)

        let nonTransparentPixels = pixels.count { $0.a > 0 }
        #expect(nonTransparentPixels == Int(width * height))
    }

    @Test("directional shadow pass darkens occluded framebuffer pixels",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU shadow smoke test"))
    func directionalShadowPassDarkensOccludedPixels() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 96
        let height: UInt32 = 96
        let scene = Self.makeShadowScene()
        let noShadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true
            ),
            frameIndex: 0,
            width: width,
            height: height
        )
        let shadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: true,
                enableOffscreenViewport: true
            ),
            frameIndex: 1,
            width: width,
            height: height
        )
        try writeDebugPPMIfRequested(
            pixels: shadowPixels,
            width: width,
            height: height,
            environmentKey: "GUAVA_GPU_SHADOW_OUTPUT"
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.depthPrepass))
        #expect(stats.activePasses.contains(.shadowPass))
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.tonemap))
        #expect(stats.passEncodeNS.keys.contains(.depthPrepass))
        #expect(stats.passEncodeNS.keys.contains(.shadowPass))
        #expect(stats.passDrawCallCounts[.depthPrepass] == 2)
        #expect(stats.passDrawCallCounts[.shadowPass] == 2)
        #expect(stats.passDrawCallCounts[.basePass] == 2)
        #expect(stats.shadowedLightCount == 1)
        #expect(stats.shadowMapResolution == RenderShadowSettings.directionalPreview.mapResolution)

        let darkerPixels = zip(noShadowPixels, shadowPixels).filter { before, after in
            after.luminance + 10 < before.luminance
        }.count
        let noShadowAverage = averageLuminance(noShadowPixels)
        let shadowAverage = averageLuminance(shadowPixels)

        #expect(darkerPixels > Int(width * height) / 64)
        #expect(shadowAverage + 1.0 < noShadowAverage)
    }

    @Test("multi directional shadow atlas encodes one tile per selected light",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU shadow atlas smoke test"))
    func multiDirectionalShadowAtlasEncodesOneTilePerLight() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        var scene = Self.makeShadowScene()
        scene.lights.append(
            RenderLight(
                type: .directional,
                direction: SIMD3<Float>(-0.60, -1.0, 0.42),
                color: SIMD3<Float>(0.78, 0.84, 1.0),
                intensity: 1.4
            )
        )

        let width: UInt32 = 96
        let height: UInt32 = 96
        let noShadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true
            ),
            frameIndex: 10,
            width: width,
            height: height
        )
        let shadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                shadowSettings: RenderShadowSettings(
                    enabled: true,
                    maxShadowedDirectionalLights: 2
                ),
                enableOffscreenViewport: true
            ),
            frameIndex: 11,
            width: width,
            height: height
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.shadowedLightCount == 2)
        #expect(stats.shadowMapResolution == RenderShadowSettings.directionalPreview.mapResolution)
        #expect(stats.passDrawCallCounts[.shadowPass] == scene.instances.count * 2)
        #expect(stats.passDrawCallCounts[.basePass] == scene.instances.count)

        let darkerPixels = zip(noShadowPixels, shadowPixels).filter { before, after in
            after.luminance + 8 < before.luminance
        }.count
        #expect(darkerPixels > Int(width * height) / 80)
    }

    @Test("directional cascades encode one atlas tile per cascade",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the real GPU cascaded shadow smoke test"))
    func directionalCascadesEncodeOneAtlasTilePerCascade() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let scene = Self.makeShadowScene()
        let width: UInt32 = 96
        let height: UInt32 = 96
        let noShadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: false,
                enableOffscreenViewport: true
            ),
            frameIndex: 20,
            width: width,
            height: height
        )
        let shadowPixels = try renderPixels(
            renderer: renderer,
            backend: backend,
            scene: scene,
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                shadowSettings: RenderShadowSettings(
                    enabled: true,
                    maxShadowedDirectionalLights: 1,
                    directionalCascadeCount: 3
                ),
                enableOffscreenViewport: true
            ),
            frameIndex: 21,
            width: width,
            height: height
        )

        let stats = renderer.currentFrameStats()
        #expect(stats.shadowedLightCount == 1)
        #expect(stats.shadowTileCount == 3)
        #expect(stats.shadowCascadeCount == 3)
        #expect(stats.shadowMapResolution == RenderShadowSettings.directionalPreview.mapResolution)
        #expect(stats.shadowAtlasResolution == RenderShadowSettings.directionalPreview.mapResolution * 2)
        #expect(stats.passDrawCallCounts[.shadowPass] == scene.instances.count * 3)

        let darkerPixels = zip(noShadowPixels, shadowPixels).filter { before, after in
            after.luminance + 8 < before.luminance
        }.count
        #expect(darkerPixels > Int(width * height) / 80)
    }

    @Test("skinned mesh with non-empty joint palette does not crash the GPU pipeline",
          .enabled(if: gpuSmokeEnabled, "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the skinned mesh GPU smoke test"))
    func skinnedMeshPaletteDoesNotCrashGPUPipeline() throws {
        let backend = WGPUBackend(
            config: WGPUDeviceConfig(
                validationEnabled: true,
                preferredBackends: WGPUBackendPreference.platformDefaultOrder
            )
        )
        try backend.initialize()

        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        defer {
            renderer = nil
            try? backend.shutdown()
        }

        guard let renderer else {
            Issue.record("renderer was not created")
            return
        }

        renderer.initialize()

        let width: UInt32 = 64
        let height: UInt32 = 64

        let skinnedEntity = EntityID(index: 1, generation: 1)
        var palette = JointPaletteMap()
        palette.palettes[skinnedEntity] = JointPalette(matrices: [matrix_identity_float4x4])

        let packet = RenderPacket(
            frameIndex: 0,
            deltaTime: 1.0 / 60.0,
            drawableSize: RenderDrawableSize(width: width, height: height),
            scene: Self.makeSmokeScene(),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: 1),
            renderSettings: RenderSettings(
                stage: .r3ViewportInterop,
                enableOffscreenViewport: true
            ),
            simulationTimeSeconds: 0,
            jointPaletteMap: palette
        )

        renderer.render(packet: packet)

        let stats = renderer.currentFrameStats()
        #expect(stats.activePasses.contains(.basePass))
        #expect(stats.activePasses.contains(.viewportResolve))

        let viewport = renderer.currentViewportSurfaceState()
        #expect(viewport.isValid)
        #expect(viewport.width == width)
        #expect(viewport.height == height)
    }

    private static func makeSmokeScene() -> RenderScene {
        RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(0, 0, 3.2),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 20
            ),
            instances: [
                RenderInstance(
                    meshIndex: 0,
                    transform: matrix_identity_float4x4,
                    colorTint: SIMD3<Float>(1.0, 0.72, 0.55),
                    material: RenderMaterial(
                        baseColorFactor: SIMD4<Float>(1.0, 0.82, 0.72, 1.0),
                        roughnessFactor: 0.65
                    )
                )
            ],
            lights: [
                RenderLight(
                    type: .directional,
                    direction: SIMD3<Float>(0, 0, -1),
                    color: SIMD3<Float>(1.0, 0.96, 0.90),
                    intensity: 1.25
                )
            ],
            environment: RenderEnvironment(
                ambientColor: SIMD3<Float>(0.12, 0.14, 0.18),
                ambientIntensity: 0.18,
                exposure: 1
            )
        )
    }

    private static func makeShadowScene() -> RenderScene {
        RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(2.4, 1.6, 3.0),
                target: SIMD3<Float>(0, -0.35, 0),
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 4,
                near: 0.1,
                far: 30
            ),
            instances: [
                RenderInstance(
                    meshIndex: 0,
                    transform: translation(SIMD3<Float>(0, -0.65, 0))
                        * scale(SIMD3<Float>(4.5, 0.08, 4.5)),
                    colorTint: SIMD3<Float>(0.96, 0.94, 0.88),
                    material: RenderMaterial(
                        baseColorFactor: SIMD4<Float>(0.96, 0.94, 0.88, 1)
                    )
                ),
                RenderInstance(
                    meshIndex: 0,
                    transform: translation(SIMD3<Float>(-0.15, -0.10, 0.05))
                        * scale(SIMD3<Float>(0.85, 0.85, 0.85)),
                    colorTint: SIMD3<Float>(1.0, 0.45, 0.23),
                    material: RenderMaterial(
                        baseColorFactor: SIMD4<Float>(1.0, 0.45, 0.23, 1)
                    )
                ),
            ],
            lights: [
                RenderLight(
                    type: .directional,
                    direction: SIMD3<Float>(0.45, -1.0, -0.35),
                    color: SIMD3<Float>(1.0, 0.96, 0.88),
                    intensity: 1.8
                )
            ],
            environment: RenderEnvironment(
                ambientColor: SIMD3<Float>(0.20, 0.22, 0.26),
                ambientIntensity: 0.16,
                exposure: 1
            )
        )
    }
}

private struct BGRAPixel: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    func distance(from other: BGRAPixel) -> Int {
        abs(Int(r) - Int(other.r))
            + abs(Int(g) - Int(other.g))
            + abs(Int(b) - Int(other.b))
    }

    var luminance: Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }
}

private func renderPixels(
    renderer: WGPURenderer,
    backend: WGPUBackend,
    scene: RenderScene,
    settings: RenderSettings,
    frameIndex: Int,
    width: UInt32,
    height: UInt32
) throws -> [BGRAPixel] {
    let packet = RenderPacket(
        frameIndex: frameIndex,
        deltaTime: 1.0 / 60.0,
        drawableSize: RenderDrawableSize(width: width, height: height),
        scene: scene,
        sceneSnapshot: SceneRuntimeSnapshot(entityCount: scene.instances.count, revision: UInt64(frameIndex + 1)),
        renderSettings: settings,
        simulationTimeSeconds: Double(frameIndex) / 60.0
    )
    renderer.render(packet: packet)

    guard let texture = renderer.offscreenColorTexture else {
        Issue.record("expected renderer to retain an offscreen color texture")
        return []
    }
    return try readbackBGRA8(
        texture: texture,
        width: width,
        height: height,
        backend: backend
    )
}

private func readbackBGRA8(
    texture: GPUTexture,
    width: UInt32,
    height: UInt32,
    backend: WGPUBackend
) throws -> [BGRAPixel] {
    let bytesPerPixel: UInt32 = 4
    let unpaddedBytesPerRow = width * bytesPerPixel
    let bytesPerRow = alignedCopyBytesPerRow(unpaddedBytesPerRow)
    let bufferSize = UInt64(bytesPerRow * height)
    let readback = try backend.createBuffer(
        size: bufferSize,
        usage: [.copyDst, .mapRead]
    )

    let encoder = try backend.createCommandEncoder()
    encoder.copyTextureToBuffer(
        source: texture,
        destination: readback,
        bytesPerRow: bytesPerRow,
        rowsPerImage: height,
        width: width,
        height: height
    )
    let commandBuffer = try encoder.finish()
    backend.submit(commandBuffer)

    try backend.bufferMapSync(readback, size: bufferSize)
    defer { readback.unmap() }

    guard let mapped = readback.getMappedRange(size: bufferSize) else {
        Issue.record("readback buffer mapping returned nil")
        return []
    }

    let bytes = UnsafeRawBufferPointer(
        start: mapped,
        count: Int(bufferSize)
    )
    var pixels: [BGRAPixel] = []
    pixels.reserveCapacity(Int(width * height))

    for y in 0..<Int(height) {
        let rowStart = y * Int(bytesPerRow)
        for x in 0..<Int(width) {
            let offset = rowStart + x * Int(bytesPerPixel)
            pixels.append(
                BGRAPixel(
                    r: bytes[offset + 2],
                    g: bytes[offset + 1],
                    b: bytes[offset + 0],
                    a: bytes[offset + 3]
                )
            )
        }
    }

    return pixels
}

private func alignedCopyBytesPerRow(_ bytesPerRow: UInt32) -> UInt32 {
    let alignment: UInt32 = 256
    return ((bytesPerRow + alignment - 1) / alignment) * alignment
}

private func writeDebugPPMIfRequested(
    pixels: [BGRAPixel],
    width: UInt32,
    height: UInt32,
    environmentKey: String = "GUAVA_GPU_SMOKE_OUTPUT"
) throws {
    guard let output = ProcessInfo.processInfo.environment[environmentKey],
          !output.isEmpty
    else {
        return
    }

    var data = Data("P6\n\(width) \(height)\n255\n".utf8)
    data.reserveCapacity(data.count + pixels.count * 3)
    for pixel in pixels {
        data.append(pixel.r)
        data.append(pixel.g)
        data.append(pixel.b)
    }
    try data.write(to: URL(fileURLWithPath: output))
}

private func averageLuminance(_ pixels: [BGRAPixel]) -> Double {
    guard !pixels.isEmpty else { return 0 }
    return pixels.reduce(0) { $0 + $1.luminance } / Double(pixels.count)
}

private func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, value.x),
        SIMD4<Float>(0, 1, 0, value.y),
        SIMD4<Float>(0, 0, 1, value.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func scale(_ value: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(value.x, 0, 0, 0),
        SIMD4<Float>(0, value.y, 0, 0),
        SIMD4<Float>(0, 0, value.z, 0),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
