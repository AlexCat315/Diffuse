import Foundation
import SIMDCompat

/// CPU-baked studio environment for image-based lighting. Produces an
/// equirectangular HDR (rgba16Float) image plus a box-filtered mip chain that
/// stands in for a prefiltered specular environment: mip 0 is a sharp mirror,
/// higher mips approximate rougher reflections, and the smallest mip doubles as
/// a crude diffuse irradiance. A dark "room" with a few bright soft-box panels
/// is exactly what makes polished metal read as gunmetal/chrome — dark body,
/// bright streak highlights — which a flat ambient or the scene's stylized sky
/// cannot provide.
enum StudioEnvironmentIBL {
    static let baseWidth = 256
    static let baseHeight = 128
    static let mipCount = 6          // 256x128 … 8x4
    static let maxLOD: Float = 5.0   // mipCount - 1

    struct MipLevel {
        let width: Int
        let height: Int
        let halfRGBA: [UInt16]
    }

    /// All mip levels, each as packed half-float RGBA, ready for per-level upload.
    static func generate() -> [MipLevel] {
        // Base level in full float.
        var current = [SIMD3<Float>](repeating: .zero, count: baseWidth * baseHeight)
        for y in 0..<baseHeight {
            for x in 0..<baseWidth {
                let u = (Float(x) + 0.5) / Float(baseWidth)
                let v = (Float(y) + 0.5) / Float(baseHeight)
                current[y * baseWidth + x] = radiance(forDirection: direction(u: u, v: v))
            }
        }

        var floatLevels: [(w: Int, h: Int, px: [SIMD3<Float>])] = [(baseWidth, baseHeight, current)]
        var w = baseWidth, h = baseHeight
        while floatLevels.count < mipCount, w > 1 || h > 1 {
            let nw = max(1, w / 2)
            let nh = max(1, h / 2)
            let src = floatLevels[floatLevels.count - 1].px
            var dst = [SIMD3<Float>](repeating: .zero, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    var sum = SIMD3<Float>.zero
                    var n: Float = 0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let sx = min(w - 1, x * 2 + dx)
                            let sy = min(h - 1, y * 2 + dy)
                            sum += src[sy * w + sx]
                            n += 1
                        }
                    }
                    dst[y * nw + x] = sum / n
                }
            }
            floatLevels.append((nw, nh, dst))
            w = nw; h = nh
        }

        return floatLevels.map { level in
            var half = [UInt16](repeating: 0, count: level.w * level.h * 4)
            for i in 0..<(level.w * level.h) {
                let c = level.px[i]
                half[i * 4 + 0] = floatToHalf(c.x)
                half[i * 4 + 1] = floatToHalf(c.y)
                half[i * 4 + 2] = floatToHalf(c.z)
                half[i * 4 + 3] = floatToHalf(1.0)
            }
            return MipLevel(width: level.w, height: level.h, halfRGBA: half)
        }
    }

    // MARK: - Environment definition

    /// Equirect (u, v) → world direction. Matches `equirect_uv` in mesh.wgsl:
    /// u maps to longitude atan2(z, x), v maps to latitude acos(y).
    private static func direction(u: Float, v: Float) -> SIMD3<Float> {
        let phi = (u - 0.5) * 2.0 * Float.pi
        let theta = v * Float.pi
        let sinTheta = sin(theta)
        return SIMD3<Float>(sinTheta * cos(phi), cos(theta), sinTheta * sin(phi))
    }

    private static func radiance(forDirection dir: SIMD3<Float>) -> SIMD3<Float> {
        let up = max(dir.y, 0.0)
        // Dark room with a faintly lit ceiling and an even darker floor.
        var c = SIMD3<Float>(0.010, 0.010, 0.013)
        c += SIMD3<Float>(0.030, 0.033, 0.040) * up
        c += SIMD3<Float>(0.004, 0.004, 0.005) * max(-dir.y, 0.0)
        // Bright soft-box panels (HDR). Broad, soft-edged so polished metal
        // catches them as clean streaks.
        c += softbox(dir, simd_normalize(SIMD3<Float>(0.35, 0.55, 0.75)), 0.80, 0.93,
                     SIMD3<Float>(15.0, 15.0, 14.0))   // key, upper front-right
        c += softbox(dir, simd_normalize(SIMD3<Float>(-0.65, 0.45, 0.25)), 0.86, 0.97,
                     SIMD3<Float>(3.6, 4.0, 4.8))       // fill, upper left (cool)
        c += softbox(dir, simd_normalize(SIMD3<Float>(-0.10, 0.40, -0.92)), 0.88, 0.98,
                     SIMD3<Float>(5.5, 5.0, 4.4))       // rim, behind (warm)
        return c
    }

    private static func softbox(_ dir: SIMD3<Float>,
                                _ center: SIMD3<Float>,
                                _ inner: Float,
                                _ outer: Float,
                                _ color: SIMD3<Float>) -> SIMD3<Float> {
        let d = simd_dot(dir, center)
        return color * smoothstep(inner, outer, d)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / max(edge1 - edge0, 1e-5)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Half-float packing

    /// IEEE-754 binary32 → binary16. Adequate for the positive HDR values here
    /// (no subnormal/round-to-nearest handling needed for an environment bake).
    static func floatToHalf(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x007F_FFFF
        if exponent <= 0 {
            return sign
        }
        if exponent >= 31 {
            return sign | 0x7C00
        }
        return sign | UInt16(exponent << 10) | UInt16(mantissa >> 13)
    }
}
