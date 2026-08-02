import Foundation
import SIMDCompat

public struct PathTracerConfig: Sendable {
    public var maxBounces: Int
    public var samplesPerPixel: Int
    public var russianRouletteDepth: Int
    public var clampIndirect: Float
    public var samplingStrategy: any SamplingStrategy
    public var environmentColor: SIMD3<Float>

    public init(
        maxBounces: Int = 4,
        samplesPerPixel: Int = 64,
        russianRouletteDepth: Int = 3,
        clampIndirect: Float = 10,
        samplingStrategy: any SamplingStrategy = HaltonSampler(),
        environmentColor: SIMD3<Float> = SIMD3<Float>(0.08, 0.1, 0.14)
    ) {
        self.maxBounces = maxBounces
        self.samplesPerPixel = samplesPerPixel
        self.russianRouletteDepth = russianRouletteDepth
        self.clampIndirect = clampIndirect
        self.samplingStrategy = samplingStrategy
        self.environmentColor = environmentColor
    }
}

public struct PathTracerState: Sendable {
    public var completedSamples: Int = 0
    public var totalSamples: Int
    public var isComplete: Bool { completedSamples >= totalSamples }

    public var progress: Float {
        guard totalSamples > 0 else { return 0 }
        return Float(completedSamples) / Float(totalSamples)
    }

    public init(totalSamples: Int) {
        self.totalSamples = totalSamples
    }
}

public struct Ray: Sendable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var invDirection: SIMD3<Float>

    public init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        self.origin = origin
        self.direction = normalizedOrFallback(direction,
                                              fallback: SIMD3<Float>(0, 0, -1))
        self.invDirection = SIMD3<Float>(
            x: 1 / (abs(self.direction.x) > 1e-8 ? self.direction.x : 1e-8),
            y: 1 / (abs(self.direction.y) > 1e-8 ? self.direction.y : 1e-8),
            z: 1 / (abs(self.direction.z) > 1e-8 ? self.direction.z : 1e-8)
        )
    }

    public func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}

public struct CameraRay: Sendable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var pixelX: Int
    public var pixelY: Int

    public init(origin: SIMD3<Float>,
                direction: SIMD3<Float>,
                pixelX: Int,
                pixelY: Int) {
        self.origin = origin
        self.direction = direction
        self.pixelX = pixelX
        self.pixelY = pixelY
    }
}

public protocol SceneGeometry: Sendable {
    func intersect(ray: Ray) -> HitResult?
    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)
}

public struct HitResult: Sendable {
    public var t: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var albedo: SIMD3<Float>
    public var emission: SIMD3<Float>
    public var roughness: Float
    public var metallic: Float

    public init(
        t: Float = .infinity,
        position: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        albedo: SIMD3<Float> = SIMD3<Float>(0.8, 0.8, 0.8),
        emission: SIMD3<Float> = .zero,
        roughness: Float = 0.5,
        metallic: Float = 0
    ) {
        self.t = t
        self.position = position
        self.normal = normal
        self.albedo = albedo
        self.emission = emission
        self.roughness = roughness
        self.metallic = metallic
    }

    public var isHit: Bool { t < Float.infinity }
}

public final class PathTracer: @unchecked Sendable {
    public let config: PathTracerConfig
    public let aovRegistry: AOVRegistry
    public private(set) var state: PathTracerState

    public init(config: PathTracerConfig = PathTracerConfig(),
                aovRegistry: AOVRegistry = AOVRegistry()) {
        self.config = config
        self.aovRegistry = aovRegistry
        self.state = PathTracerState(totalSamples: config.samplesPerPixel)
    }

    // MARK: - Progressive rendering

    public func renderPass(
        width: Int,
        height: Int,
        camera: CameraRay,
        geometry: any SceneGeometry,
        sample: Int
    ) -> SIMD3<Float> {
        guard width > 0, height > 0 else { return config.environmentColor }
        let sampler = config.samplingStrategy
        let jitter = sampler.sample2D(sample * width * height + camera.pixelY * width + camera.pixelX, sample: sample)
        let u = (Float(camera.pixelX) + jitter.x) / Float(width)
        let v = (Float(camera.pixelY) + jitter.y) / Float(height)
        let projection = SimpleCamera(
            origin: camera.origin,
            forward: camera.direction,
            up: SIMD3<Float>(0, 1, 0),
            fovYRadians: .pi / 4,
            aspectRatio: Float(width) / Float(height)
        )
        let ray = projection.ray(forUV: SIMD2<Float>(u, v))
        return trace(ray: ray, geometry: geometry, depth: 0)
    }

    public func accumulatePass(
        into framebuffer: inout [Float],
        width: Int,
        height: Int,
        cameraOrigin: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        cameraFOVYRadians: Float = .pi / 4,
        cameraAspectRatio: Float? = nil,
        geometry: any SceneGeometry
    ) {
        guard width > 0, height > 0 else { return }
        let camera = SimpleCamera(
            origin: cameraOrigin,
            forward: cameraForward,
            up: cameraUp,
            fovYRadians: cameraFOVYRadians,
            aspectRatio: cameraAspectRatio ?? (height > 0 ? Float(width) / Float(height) : 1)
        )
        let sampler = config.samplingStrategy
        let s = state.completedSamples
        let pixelCount = width * height
        guard framebuffer.count >= pixelCount * 3 else { return }

        for y in 0..<height {
            for x in 0..<width {
                let jitter = sampler.sample2D(x + y * width, sample: s)
                let u = (Float(x) + jitter.x) / Float(width)
                let v = (Float(y) + jitter.y) / Float(height)
                let ray = camera.ray(forUV: SIMD2<Float>(u, v))
                let color = trace(ray: ray, geometry: geometry, depth: 0)
                let idx = (y * width + x) * 3
                let invSamples = 1 / Float(s + 1)
                framebuffer[idx + 0] = (framebuffer[idx + 0] * Float(s) + color.x) * invSamples
                framebuffer[idx + 1] = (framebuffer[idx + 1] * Float(s) + color.y) * invSamples
                framebuffer[idx + 2] = (framebuffer[idx + 2] * Float(s) + color.z) * invSamples
            }
        }
        state.completedSamples += 1
    }

    // MARK: - Core path trace

    private func trace(ray: Ray, geometry: any SceneGeometry, depth: Int) -> SIMD3<Float> {
        guard let hit = geometry.intersect(ray: ray) else {
            return config.environmentColor
        }

        // Direct emission
        var color = hit.emission

        // Russian roulette termination
        if depth >= config.russianRouletteDepth {
            let survivalProbability = min(max(hit.albedo.max(), 0.1), 1.0)
            if Float.random(in: 0...1) > survivalProbability {
                return color
            }
        }

        guard depth < config.maxBounces else { return color }

        // Simple diffuse bounce (Lambertian)
        let bounceDir = cosineWeightedHemisphere(normal: hit.normal)
        let bounceRay = Ray(origin: hit.position + hit.normal * 0.001,
                            direction: bounceDir)
        let indirectColor = trace(ray: bounceRay, geometry: geometry, depth: depth + 1)

        // Clamp fireflies
        let clamped = SIMD3<Float>(
            min(indirectColor.x, config.clampIndirect),
            min(indirectColor.y, config.clampIndirect),
            min(indirectColor.z, config.clampIndirect)
        )
        color += hit.albedo * clamped

        return color
    }
}

private struct SimpleCamera {
    let origin: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let halfHeight: Float
    let halfWidth: Float

    init(origin: SIMD3<Float>,
         forward: SIMD3<Float>,
         up: SIMD3<Float>,
         fovYRadians: Float,
         aspectRatio: Float) {
        self.origin = origin
        let safeForward = normalizedOrFallback(forward,
                                               fallback: SIMD3<Float>(0, 0, -1))
        let safeUp = normalizedOrFallback(up,
                                          fallback: SIMD3<Float>(0, 1, 0))
        var rightRaw = simd_cross(safeForward, safeUp)
        if simd_length(rightRaw) <= 0.000_001 {
            let alternateUp = abs(safeForward.y) < 0.99
                ? SIMD3<Float>(0, 1, 0)
                : SIMD3<Float>(1, 0, 0)
            rightRaw = simd_cross(safeForward, alternateUp)
        }
        let safeRight = normalizedOrFallback(rightRaw,
                                             fallback: SIMD3<Float>(1, 0, 0))
        self.forward = safeForward
        self.right = safeRight
        self.up = normalizedOrFallback(simd_cross(safeRight, safeForward),
                                       fallback: SIMD3<Float>(0, 1, 0))
        let safeFOV = fovYRadians.isFinite ? fovYRadians : .pi / 4
        let safeAspect = aspectRatio.isFinite ? aspectRatio : 1
        self.halfHeight = tanf(max(0.01, min(.pi - 0.01, safeFOV)) * 0.5)
        self.halfWidth = halfHeight * max(0.001, safeAspect)
    }

    func ray(forUV uv: SIMD2<Float>) -> Ray {
        let px = (2 * uv.x - 1) * halfWidth
        let py = (1 - 2 * uv.y) * halfHeight
        let dir = simd_normalize(forward + right * px + up * py)
        return Ray(origin: origin, direction: dir)
    }
}

private func cosineWeightedHemisphere(normal: SIMD3<Float>) -> SIMD3<Float> {
    let u = Float.random(in: 0...1)
    let v = Float.random(in: 0...1)
    let phi = 2 * .pi * u
    let cosTheta = sqrt(1 - v)
    let sinTheta = sqrt(v)
    let up = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
    let tangent = simd_normalize(simd_cross(up, normal))
    let bitangent = simd_cross(normal, tangent)
    return simd_normalize(
        tangent * (cos(phi) * sinTheta) +
        normal * cosTheta +
        bitangent * (sin(phi) * sinTheta)
    )
}

private func normalizedOrFallback(_ vector: SIMD3<Float>,
                                  fallback: SIMD3<Float>) -> SIMD3<Float> {
    guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
        return fallback
    }
    let length = simd_length(vector)
    guard length.isFinite, length > 0.000_001 else { return fallback }
    return vector / length
}
