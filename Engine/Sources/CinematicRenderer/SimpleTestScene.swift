import Foundation
import simd

/// A minimal test scene with a ground plane and a sphere for validating
/// the PathTracer → ColorPipeline → ImageIO pipeline end-to-end.
public struct SimpleTestScene: SceneGeometry, @unchecked Sendable {
    private let sphereRadius: Float
    private let sphereCenter: SIMD3<Float>

    public init(sphereRadius: Float = 0.5, sphereCenter: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) {
        self.sphereRadius = sphereRadius
        self.sphereCenter = sphereCenter
    }

    public func intersect(ray: Ray) -> HitResult? {
        var closest: HitResult?

        // Sphere
        if let hit = intersectSphere(ray: ray) {
            closest = hit
        }

        // Ground plane (y = 0)
        if let hit = intersectGround(ray: ray) {
            if closest == nil || hit.t < closest!.t {
                closest = hit
            }
        }

        return closest
    }

    public func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let r = sphereRadius
        let c = sphereCenter
        return (
            min: SIMD3<Float>(c.x - r, 0, c.z - r),
            max: SIMD3<Float>(c.x + r, c.y + r, c.z + r)
        )
    }

    private func intersectSphere(ray: Ray) -> HitResult? {
        let oc = ray.origin - sphereCenter
        let a = simd_dot(ray.direction, ray.direction)
        let b = 2 * simd_dot(oc, ray.direction)
        let c = simd_dot(oc, oc) - sphereRadius * sphereRadius
        let discriminant = b * b - 4 * a * c
        guard discriminant > 0 else { return nil }

        let sqrtD = sqrt(discriminant)
        let t1 = (-b - sqrtD) / (2 * a)
        let t2 = (-b + sqrtD) / (2 * a)
        let t = t1 > 0.001 ? t1 : (t2 > 0.001 ? t2 : -1)
        guard t > 0.001 else { return nil }

        let pos = ray.point(at: t)
        let normal = simd_normalize(pos - sphereCenter)
        return HitResult(
            t: t,
            position: pos,
            normal: normal,
            albedo: SIMD3<Float>(0.7, 0.3, 0.3),   // red sphere
            emission: .zero,
            roughness: 0.4,
            metallic: 0.1
        )
    }

    private func intersectGround(ray: Ray) -> HitResult? {
        guard abs(ray.direction.y) > 1e-8 else { return nil }
        let t = -ray.origin.y / ray.direction.y
        guard t > 0.001 else { return nil }

        let pos = ray.point(at: t)
        // Checkerboard pattern
        let checker = (Int(floor(pos.x * 2)) + Int(floor(pos.z * 2))) & 1
        let albedo: SIMD3<Float> = checker == 0
            ? SIMD3<Float>(0.8, 0.8, 0.8)
            : SIMD3<Float>(0.2, 0.2, 0.2)

        return HitResult(
            t: t,
            position: pos,
            normal: SIMD3<Float>(0, 1, 0),
            albedo: albedo,
            emission: .zero,
            roughness: 0.9,
            metallic: 0
        )
    }
}
