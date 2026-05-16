import RHIWGPU
import SceneRuntime
import simd

/// One mesh resident on the GPU.
struct GPUMesh {
    let vertexBuffer: GPUBuffer
    let indexBuffer: GPUBuffer
    let indexCount: UInt32
    let name: String
}

extension GPUMesh: @unchecked Sendable {}

/// Per-instance GPU resources (uniform buffer + bind group). One slot per draw call.
struct InstanceResources {
    let uniformBuffer: GPUBuffer
    let bindGroup: GPUBindGroup
}

extension InstanceResources: @unchecked Sendable {}

struct InstanceResourceKey: Equatable, Sendable {
    let meshIndex: Int
    let baseColorTextureIndex: Int?
}

let maxSceneLightUniformCount = 8
let defaultShadowMapResolution: UInt32 = 1024

struct SceneLightUniform: Equatable, Sendable {
    var positionAndType: SIMD4<Float>
    var directionAndRange: SIMD4<Float>
    var colorAndIntensity: SIMD4<Float>
    var spotAnglesAndPadding: SIMD4<Float>

    static let zero = SceneLightUniform(
        positionAndType: .zero,
        directionAndRange: .zero,
        colorAndIntensity: .zero,
        spotAnglesAndPadding: .zero
    )

    init(positionAndType: SIMD4<Float>,
         directionAndRange: SIMD4<Float>,
         colorAndIntensity: SIMD4<Float>,
         spotAnglesAndPadding: SIMD4<Float>) {
        self.positionAndType = positionAndType
        self.directionAndRange = directionAndRange
        self.colorAndIntensity = colorAndIntensity
        self.spotAnglesAndPadding = spotAnglesAndPadding
    }

    init(_ light: RenderLight) {
        self.init(
            positionAndType: SIMD4<Float>(light.position, light.type.uniformCode),
            directionAndRange: SIMD4<Float>(normalized(light.direction), light.range),
            colorAndIntensity: SIMD4<Float>(light.color, light.intensity),
            spotAnglesAndPadding: SIMD4<Float>(
                light.spotInnerAngleRadians,
                light.spotOuterAngleRadians,
                0,
                0
            )
        )
    }
}

struct SceneLightUniforms: Equatable, Sendable {
    var ambientColorAndIntensity: SIMD4<Float>
    var exposureAndLightCount: SIMD4<Float>
    var light0: SceneLightUniform
    var light1: SceneLightUniform
    var light2: SceneLightUniform
    var light3: SceneLightUniform
    var light4: SceneLightUniform
    var light5: SceneLightUniform
    var light6: SceneLightUniform
    var light7: SceneLightUniform

    static let byteSize = UInt64(MemoryLayout<SceneLightUniforms>.stride)

    init(scene: RenderScene) {
        let packedLights = scene.lights.prefix(maxSceneLightUniformCount).map(SceneLightUniform.init)
        self.ambientColorAndIntensity = SIMD4<Float>(
            scene.environment.ambientColor,
            scene.environment.ambientIntensity
        )
        self.exposureAndLightCount = SIMD4<Float>(
            scene.environment.exposure,
            Float(packedLights.count),
            0,
            0
        )
        self.light0 = Self.light(at: 0, in: packedLights)
        self.light1 = Self.light(at: 1, in: packedLights)
        self.light2 = Self.light(at: 2, in: packedLights)
        self.light3 = Self.light(at: 3, in: packedLights)
        self.light4 = Self.light(at: 4, in: packedLights)
        self.light5 = Self.light(at: 5, in: packedLights)
        self.light6 = Self.light(at: 6, in: packedLights)
        self.light7 = Self.light(at: 7, in: packedLights)
    }

    private static func light(at index: Int, in lights: [SceneLightUniform]) -> SceneLightUniform {
        lights.indices.contains(index) ? lights[index] : .zero
    }
}

struct ShadowUniforms: Equatable, Sendable {
    var lightViewProjection: simd_float4x4
    var params: SIMD4<Float>

    static let disabled = ShadowUniforms(
        lightViewProjection: matrix_identity_float4x4,
        params: SIMD4<Float>(0, 0.004, 0.55, Float(defaultShadowMapResolution))
    )

    static func disabled(mapResolution: UInt32) -> ShadowUniforms {
        ShadowUniforms(
            lightViewProjection: matrix_identity_float4x4,
            params: SIMD4<Float>(0, 0.004, 0.55, Float(mapResolution))
        )
    }

    var isEnabled: Bool {
        params.x > 0.5
    }
}

/// Shared uniform-buffer path using dynamic bind offsets.
struct DynamicInstanceResources {
    let uniformBuffer: GPUBuffer
    let bindGroup: GPUBindGroup
    let stride: UInt64
    let capacity: Int
}

extension DynamicInstanceResources: @unchecked Sendable {}

struct RenderTextureTarget {
    let texture: GPUTexture
    let view: GPUTextureView
}

struct ShadowMapTarget {
    let colorTexture: GPUTexture
    let colorView: GPUTextureView
    let depthTexture: GPUTexture
    let depthView: GPUTextureView
    let size: UInt32
}

struct GPUMeshTextureResource {
    let texture: GPUTexture
    let view: GPUTextureView
    let width: UInt32
    let height: UInt32
    let sourcePath: String
}

struct BasePassEncodingReport {
    let drawCallCount: Int
    let renderBundleCount: Int
    let parallelJobCount: Int
    let bundleRecordNS: UInt64
}

private extension RenderLightType {
    var uniformCode: Float {
        switch self {
        case .directional:
            return 0
        case .point:
            return 1
        case .spot:
            return 2
        }
    }
}

private func normalized(_ value: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(value)
    guard lengthSquared > 0.000_001 else {
        return SIMD3<Float>(0, -1, 0)
    }
    return value / sqrt(lengthSquared)
}
