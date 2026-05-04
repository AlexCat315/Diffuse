import Foundation
import simd

public struct PathTracerConfig: Sendable {
    public var maxBounces: Int
    public var samplesPerPixel: Int
    public var russianRouletteDepth: Int
    public var clampIndirect: Float
    public var samplingStrategy: any SamplingStrategy

    public init(
        maxBounces: Int = 4,
        samplesPerPixel: Int = 64,
        russianRouletteDepth: Int = 3,
        clampIndirect: Float = 10,
        samplingStrategy: any SamplingStrategy = HaltonSampler()
    ) {
        self.maxBounces = maxBounces
        self.samplesPerPixel = samplesPerPixel
        self.russianRouletteDepth = russianRouletteDepth
        self.clampIndirect = clampIndirect
        self.samplingStrategy = samplingStrategy
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
        self.direction = simd_normalize(direction)
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
        let sampler = config.samplingStrategy
        let jitter = sampler.sample2D(sample * width * height + camera.pixelY * width + camera.pixelX, sample: sample)
        let u = (Float(camera.pixelX) + jitter.x) / Float(width)
        let v = (Float(camera.pixelY) + jitter.y) / Float(height)
        let ray = camera.ray(forUV: SIMD2<Float>(u, v))
        return trace(ray: ray, geometry: geometry, depth: 0)
    }

    public func accumulatePass(
        into framebuffer: inout [Float],
        width: Int,
        height: Int,
        cameraOrigin: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        geometry: any SceneGeometry
    ) {
        let camera = SimpleCamera(
            origin: cameraOrigin,
            forward: cameraForward,
            up: cameraUp,
            fovDegrees: 45
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
            return SIMD3<Float>(0, 0, 0) // Sky / environment (black for now)
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

    init(origin: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, fovDegrees: Float) {
        self.origin = origin
        self.forward = simd_normalize(forward)
        self.right = simd_normalize(simd_cross(self.forward, up))
        self.up = simd_normalize(simd_cross(self.right, self.forward))
        let aspect: Float = 1.0 // square default
        self.halfHeight = tanf(fovDegrees * .pi / 360)
        self.halfWidth = halfHeight * aspect
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

extension CameraRay {
    func ray(forUV uv: SIMD2<Float>) -> Ray {
        // Simplification: derive from stored direction + pixel offset.
        // Full camera model should replace this with proper projection.
        Ray(origin: origin, direction: direction)
    }
}
