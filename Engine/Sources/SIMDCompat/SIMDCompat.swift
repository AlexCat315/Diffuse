// Cross-platform SIMD compatibility layer.
// On Apple platforms, re-exports the native simd framework.
// On Windows/Linux, provides equivalent types and functions.

#if canImport(simd)
@_exported import simd
#else
// Re-export Foundation so consumers get math functions (tan, sqrt, sin, cos, etc.)
@_exported import Foundation

// MARK: - Free functions (scalar vector operations)

public func simd_min(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { pointwiseMin(a, b) }
public func simd_min(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { pointwiseMin(a, b) }
public func simd_min(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> { pointwiseMin(a, b) }
public func simd_max(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { pointwiseMax(a, b) }
public func simd_max(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { pointwiseMax(a, b) }
public func simd_max(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> { pointwiseMax(a, b) }

public func simd_clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(x, lo), hi) }
public func simd_clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(x, lo), hi) }
public func simd_clamp(_ x: SIMD2<Float>, _ lo: SIMD2<Float>, _ hi: SIMD2<Float>) -> SIMD2<Float> {
    simd_min(simd_max(x, lo), hi)
}
public func simd_clamp(_ x: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> SIMD3<Float> {
    simd_min(simd_max(x, lo), hi)
}
public func simd_clamp(_ x: SIMD4<Float>, _ lo: SIMD4<Float>, _ hi: SIMD4<Float>) -> SIMD4<Float> {
    simd_min(simd_max(x, lo), hi)
}

public func simd_mix(_ x: SIMD3<Float>, _ y: SIMD3<Float>, _ t: SIMD3<Float>) -> SIMD3<Float> {
    x + (y - x) * t
}

public func simd_mix(_ x: Float, _ y: Float, _ t: Float) -> Float { x + (y - x) * t }
public func simd_mix(_ x: SIMD2<Float>, _ y: SIMD2<Float>, _ t: Float) -> SIMD2<Float> { x + (y - x) * t }
public func simd_mix(_ x: SIMD4<Float>, _ y: SIMD4<Float>, _ t: SIMD4<Float>) -> SIMD4<Float> { x + (y - x) * t }

public func simd_abs(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
}

public func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a * b).sum() }
public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
public func simd_dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { (a * b).sum() }
public func simd_dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }
public func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
public func simd_dot(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> Double { (a * b).sum() }

public func simd_length(_ v: SIMD2<Float>) -> Float { sqrt((v * v).sum()) }
public func simd_length(_ v: SIMD3<Float>) -> Float { sqrt((v * v).sum()) }
public func simd_length(_ v: SIMD4<Float>) -> Float { sqrt((v * v).sum()) }

// Non-prefixed aliases matching Apple simd module's length() shorthand
public func length(_ v: SIMD2<Float>) -> Float { simd_length(v) }
public func length(_ v: SIMD3<Float>) -> Float { simd_length(v) }
public func length(_ v: SIMD4<Float>) -> Float { simd_length(v) }

public func simd_length_squared(_ v: SIMD2<Float>) -> Float { (v * v).sum() }
public func simd_length_squared(_ v: SIMD3<Float>) -> Float { (v * v).sum() }
public func simd_length_squared(_ v: SIMD4<Float>) -> Float { (v * v).sum() }

public func simd_distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_length(a - b) }
public func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) }
public func simd_distance(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_length(a - b) }
public func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_length(a - b) }
public func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) }
public func distance(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_length(a - b) }
public func simd_distance_squared(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_length_squared(a - b) }
public func simd_distance_squared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length_squared(a - b) }
public func simd_distance_squared(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_length_squared(a - b) }

public func simd_normalize(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let len = simd_length(v); return len > 0 ? v / len : v
}
public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(v); return len > 0 ? v / len : v
}
public func simd_normalize(_ v: SIMD4<Float>) -> SIMD4<Float> {
    let len = simd_length(v); return len > 0 ? v / len : v
}

public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

// MARK: - simd_float4x4

public struct simd_float4x4: Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init() { columns = (.zero, .zero, .zero, .zero) }

    public init(columns c: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        columns = c
    }

    public init(_ col0: SIMD4<Float>, _ col1: SIMD4<Float>, _ col2: SIMD4<Float>, _ col3: SIMD4<Float>) {
        columns = (col0, col1, col2, col3)
    }

    public init(diagonal d: SIMD4<Float>) {
        columns = (
            SIMD4<Float>(d.x, 0, 0, 0),
            SIMD4<Float>(0, d.y, 0, 0),
            SIMD4<Float>(0, 0, d.z, 0),
            SIMD4<Float>(0, 0, 0, d.w)
        )
    }

    /// Scalar on the diagonal — matches Apple simd's `simd_float4x4(_ scalar)`.
    public init(_ scalar: Float) {
        self.init(diagonal: SIMD4<Float>(scalar, scalar, scalar, scalar))
    }

    // rows: each element is a row of the matrix; storage is column-major
    public init(rows: [SIMD4<Float>]) {
        precondition(rows.count == 4)
        columns = (
            SIMD4<Float>(rows[0].x, rows[1].x, rows[2].x, rows[3].x),
            SIMD4<Float>(rows[0].y, rows[1].y, rows[2].y, rows[3].y),
            SIMD4<Float>(rows[0].z, rows[1].z, rows[2].z, rows[3].z),
            SIMD4<Float>(rows[0].w, rows[1].w, rows[2].w, rows[3].w)
        )
    }

    public subscript(col: Int) -> SIMD4<Float> {
        get {
            switch col {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            case 3: return columns.3
            default: fatalError("Column index \(col) out of range for simd_float4x4")
            }
        }
        set {
            switch col {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            case 3: columns.3 = newValue
            default: fatalError("Column index \(col) out of range for simd_float4x4")
            }
        }
    }

    // Init from quaternion (rotation matrix, no translation/scale)
    public init(_ q: simd_quatf) {
        let ix = q.vector.x, iy = q.vector.y, iz = q.vector.z, r = q.vector.w
        let x2 = ix + ix, y2 = iy + iy, z2 = iz + iz
        let xx = ix * x2, xy = ix * y2, xz = ix * z2
        let yy = iy * y2, yz = iy * z2, zz = iz * z2
        let wx = r * x2, wy = r * y2, wz = r * z2
        columns = (
            SIMD4<Float>(1 - (yy + zz), xy + wz,     xz - wy,     0),
            SIMD4<Float>(xy - wz,        1 - (xx + zz), yz + wx,   0),
            SIMD4<Float>(xz + wy,        yz - wx,     1 - (xx + yy), 0),
            SIMD4<Float>(0,              0,             0,           1)
        )
    }

    // Named variant used in some call sites
    public init(rotation q: simd_quatf) { self.init(q) }

    public var transpose: simd_float4x4 { simd_transpose(self) }
    public var inverse: simd_float4x4 { simd_inverse(self) }
}

// MARK: simd_float4x4 operators

public func * (lhs: simd_float4x4, rhs: simd_float4x4) -> simd_float4x4 {
    var r = simd_float4x4()
    for i in 0..<4 {
        let c = rhs[i]
        r[i] = lhs.columns.0 * c.x + lhs.columns.1 * c.y + lhs.columns.2 * c.z + lhs.columns.3 * c.w
    }
    return r
}

public func * (lhs: simd_float4x4, rhs: SIMD4<Float>) -> SIMD4<Float> {
    lhs.columns.0 * rhs.x + lhs.columns.1 * rhs.y + lhs.columns.2 * rhs.z + lhs.columns.3 * rhs.w
}

public func *= (lhs: inout simd_float4x4, rhs: simd_float4x4) { lhs = lhs * rhs }

extension simd_float4x4: Equatable {
    public static func == (lhs: simd_float4x4, rhs: simd_float4x4) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 &&
        lhs.columns.2 == rhs.columns.2 && lhs.columns.3 == rhs.columns.3
    }
}

// MARK: simd_float4x4 global constants and functions

public let matrix_identity_float4x4 = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))

public func simd_transpose(_ m: simd_float4x4) -> simd_float4x4 {
    simd_float4x4(rows: [m.columns.0, m.columns.1, m.columns.2, m.columns.3])
}

public func simd_inverse(_ m: simd_float4x4) -> simd_float4x4 {
    // MESA-style cofactor inverse (column-major layout)
    // m[col*4+row]: m0=col0.x, m1=col0.y, m2=col0.z, m3=col0.w, m4=col1.x, ...
    let m0 = m.columns.0.x, m1 = m.columns.0.y, m2 = m.columns.0.z, m3 = m.columns.0.w
    let m4 = m.columns.1.x, m5 = m.columns.1.y, m6 = m.columns.1.z, m7 = m.columns.1.w
    let m8 = m.columns.2.x, m9 = m.columns.2.y, m10 = m.columns.2.z, m11 = m.columns.2.w
    let m12 = m.columns.3.x, m13 = m.columns.3.y, m14 = m.columns.3.z, m15 = m.columns.3.w

    let i0  =  m5*m10*m15 - m5*m11*m14 - m9*m6*m15 + m9*m7*m14 + m13*m6*m11 - m13*m7*m10
    let i4  = -m4*m10*m15 + m4*m11*m14 + m8*m6*m15 - m8*m7*m14 - m12*m6*m11 + m12*m7*m10
    let i8  =  m4*m9*m15  - m4*m11*m13 - m8*m5*m15 + m8*m7*m13 + m12*m5*m11 - m12*m7*m9
    let i12 = -m4*m9*m14  + m4*m10*m13 + m8*m5*m14 - m8*m6*m13 - m12*m5*m10 + m12*m6*m9
    let i1  = -m1*m10*m15 + m1*m11*m14 + m9*m2*m15 - m9*m3*m14 - m13*m2*m11 + m13*m3*m10
    let i5  =  m0*m10*m15 - m0*m11*m14 - m8*m2*m15 + m8*m3*m14 + m12*m2*m11 - m12*m3*m10
    let i9  = -m0*m9*m15  + m0*m11*m13 + m8*m1*m15 - m8*m3*m13 - m12*m1*m11 + m12*m3*m9
    let i13 =  m0*m9*m14  - m0*m10*m13 - m8*m1*m14 + m8*m2*m13 + m12*m1*m10 - m12*m2*m9
    let i2  =  m1*m6*m15  - m1*m7*m14  - m5*m2*m15 + m5*m3*m14 + m13*m2*m7  - m13*m3*m6
    let i6  = -m0*m6*m15  + m0*m7*m14  + m4*m2*m15 - m4*m3*m14 - m12*m2*m7  + m12*m3*m6
    let i10 =  m0*m5*m15  - m0*m7*m13  - m4*m1*m15 + m4*m3*m13 + m12*m1*m7  - m12*m3*m5
    let i14 = -m0*m5*m14  + m0*m6*m13  + m4*m1*m14 - m4*m2*m13 - m12*m1*m6  + m12*m2*m5
    let i3  = -m1*m6*m11  + m1*m7*m10  + m5*m2*m11 - m5*m3*m10 - m9*m2*m7   + m9*m3*m6
    let i7  =  m0*m6*m11  - m0*m7*m10  - m4*m2*m11 + m4*m3*m10 + m8*m2*m7   - m8*m3*m6
    let i11 = -m0*m5*m11  + m0*m7*m9   + m4*m1*m11 - m4*m3*m9  - m8*m1*m7   + m8*m3*m5
    let i15 =  m0*m5*m10  - m0*m6*m9   - m4*m1*m10 + m4*m2*m9  + m8*m1*m6   - m8*m2*m5

    let det = m0 * i0 + m1 * i4 + m2 * i8 + m3 * i12
    guard abs(det) > Float.leastNonzeroMagnitude else { return matrix_identity_float4x4 }
    let d = 1.0 / det
    return simd_float4x4(columns: (
        SIMD4<Float>(i0*d,  i1*d,  i2*d,  i3*d),
        SIMD4<Float>(i4*d,  i5*d,  i6*d,  i7*d),
        SIMD4<Float>(i8*d,  i9*d,  i10*d, i11*d),
        SIMD4<Float>(i12*d, i13*d, i14*d, i15*d)
    ))
}

// MARK: - simd_float3x3

public struct simd_float3x3: Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    public init() { columns = (.zero, .zero, .zero) }

    public init(columns c: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) { columns = c }

    public init(diagonal d: SIMD3<Float>) {
        columns = (
            SIMD3<Float>(d.x, 0, 0),
            SIMD3<Float>(0, d.y, 0),
            SIMD3<Float>(0, 0, d.z)
        )
    }

    /// Scalar on the diagonal — matches Apple simd's `simd_float3x3(_ scalar)`.
    public init(_ scalar: Float) {
        self.init(diagonal: SIMD3<Float>(scalar, scalar, scalar))
    }

    // Extract upper-left 3x3 from a 4x4
    public init(_ m: simd_float4x4) {
        columns = (
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    public init(_ q: simd_quatf) {
        let ix = q.vector.x, iy = q.vector.y, iz = q.vector.z, r = q.vector.w
        let x2 = ix + ix, y2 = iy + iy, z2 = iz + iz
        let xx = ix * x2, xy = ix * y2, xz = ix * z2
        let yy = iy * y2, yz = iy * z2, zz = iz * z2
        let wx = r * x2, wy = r * y2, wz = r * z2
        columns = (
            SIMD3<Float>(1 - (yy + zz), xy + wz, xz - wy),
            SIMD3<Float>(xy - wz, 1 - (xx + zz), yz + wx),
            SIMD3<Float>(xz + wy, yz - wx, 1 - (xx + yy))
        )
    }

    public subscript(col: Int) -> SIMD3<Float> {
        get {
            switch col {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: fatalError("Column index out of range")
            }
        }
        set {
            switch col {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: fatalError("Column index out of range")
            }
        }
    }
}

public let matrix_identity_float3x3 = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))

public func * (lhs: simd_float3x3, rhs: SIMD3<Float>) -> SIMD3<Float> {
    lhs.columns.0 * rhs.x + lhs.columns.1 * rhs.y + lhs.columns.2 * rhs.z
}

extension simd_float3x3: Equatable {
    public static func == (lhs: simd_float3x3, rhs: simd_float3x3) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 && lhs.columns.2 == rhs.columns.2
    }
}

public func * (lhs: simd_float3x3, rhs: simd_float3x3) -> simd_float3x3 {
    var r = simd_float3x3()
    for i in 0..<3 {
        let c = rhs[i]
        r[i] = lhs.columns.0 * c.x + lhs.columns.1 * c.y + lhs.columns.2 * c.z
    }
    return r
}

public func simd_transpose(_ m: simd_float3x3) -> simd_float3x3 {
    simd_float3x3(columns: (
        SIMD3<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x),
        SIMD3<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y),
        SIMD3<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z)
    ))
}

public func simd_inverse(_ m: simd_float3x3) -> simd_float3x3 {
    let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2
    let cof0 = SIMD3<Float>(c1.y*c2.z - c1.z*c2.y, c0.z*c2.y - c0.y*c2.z, c0.y*c1.z - c0.z*c1.y)
    let det = c0.x*cof0.x + c1.x*cof0.y + c2.x*cof0.z
    guard Swift.abs(det) > Float.leastNonzeroMagnitude else { return matrix_identity_float3x3 }
    let d = 1.0 / det
    let cof1 = SIMD3<Float>(c1.z*c2.x - c1.x*c2.z, c0.x*c2.z - c0.z*c2.x, c0.z*c1.x - c0.x*c1.z)
    let cof2 = SIMD3<Float>(c1.x*c2.y - c1.y*c2.x, c0.y*c2.x - c0.x*c2.y, c0.x*c1.y - c0.y*c1.x)
    // Adjugate (transposed cofactor matrix) / det
    return simd_float3x3(columns: (
        SIMD3<Float>(cof0.x*d, cof1.x*d, cof2.x*d),
        SIMD3<Float>(cof0.y*d, cof1.y*d, cof2.y*d),
        SIMD3<Float>(cof0.z*d, cof1.z*d, cof2.z*d)
    ))
}

// MARK: - simd_quatf

public struct simd_quatf: Sendable {
    // vector: SIMD4<Float>(ix, iy, iz, r) — imaginary in xyz, real in w
    public var vector: SIMD4<Float>

    public var real: Float { vector.w }
    public var imag: SIMD3<Float> { SIMD3<Float>(vector.x, vector.y, vector.z) }

    public init(vector: SIMD4<Float>) { self.vector = vector }

    public init(real: Float, imag: SIMD3<Float>) {
        vector = SIMD4<Float>(imag.x, imag.y, imag.z, real)
    }

    public init(ix: Float, iy: Float, iz: Float, r: Float) {
        vector = SIMD4<Float>(ix, iy, iz, r)
    }

    public init(angle: Float, axis: SIMD3<Float>) {
        let halfAngle = angle * 0.5
        let s = Float(Foundation.sin(Double(halfAngle)))
        let len = simd_length(axis)
        let normalizedAxis = len > 0 ? axis / len : SIMD3<Float>(0, 1, 0)
        vector = SIMD4<Float>(
            normalizedAxis.x * s, normalizedAxis.y * s, normalizedAxis.z * s,
            Float(Foundation.cos(Double(halfAngle)))
        )
    }

    /// Shortest-arc rotation that takes `from` onto `to` (both need not be unit).
    public init(from: SIMD3<Float>, to: SIMD3<Float>) {
        let f = simd_normalize(from)
        let t = simd_normalize(to)
        let d = simd_dot(f, t)
        if d >= 1 - 1e-6 {
            vector = SIMD4<Float>(0, 0, 0, 1)          // already aligned → identity
        } else if d <= -1 + 1e-6 {
            // Opposed: rotate 180° about any axis orthogonal to `f`. A 180°
            // rotation about a unit axis is the pure quaternion (axis, 0).
            var axis = simd_cross(SIMD3<Float>(1, 0, 0), f)
            if simd_length(axis) < 1e-6 { axis = simd_cross(SIMD3<Float>(0, 1, 0), f) }
            axis = simd_normalize(axis)
            vector = SIMD4<Float>(axis.x, axis.y, axis.z, 0)
        } else {
            let axis = simd_cross(f, t)
            let s = sqrt((1 + d) * 2)
            let invs = 1 / s
            vector = SIMD4<Float>(axis.x * invs, axis.y * invs, axis.z * invs, s * 0.5)
        }
    }

    // Init from 3x3 rotation matrix (Shepperd's method)
    public init(_ m: simd_float3x3) {
        let trace = m.columns.0.x + m.columns.1.y + m.columns.2.z
        if trace > 0 {
            let s: Float = 0.5 / sqrt(trace + 1.0)
            vector = SIMD4<Float>(
                (m.columns.1.z - m.columns.2.y) * s,
                (m.columns.2.x - m.columns.0.z) * s,
                (m.columns.0.y - m.columns.1.x) * s,
                0.25 / s
            )
        } else if m.columns.0.x > m.columns.1.y && m.columns.0.x > m.columns.2.z {
            let s: Float = 2.0 * sqrt(1.0 + m.columns.0.x - m.columns.1.y - m.columns.2.z)
            vector = SIMD4<Float>(
                0.25 * s,
                (m.columns.1.x + m.columns.0.y) / s,
                (m.columns.2.x + m.columns.0.z) / s,
                (m.columns.1.z - m.columns.2.y) / s
            )
        } else if m.columns.1.y > m.columns.2.z {
            let s: Float = 2.0 * sqrt(1.0 + m.columns.1.y - m.columns.0.x - m.columns.2.z)
            vector = SIMD4<Float>(
                (m.columns.1.x + m.columns.0.y) / s,
                0.25 * s,
                (m.columns.2.y + m.columns.1.z) / s,
                (m.columns.2.x - m.columns.0.z) / s
            )
        } else {
            let s: Float = 2.0 * sqrt(1.0 + m.columns.2.z - m.columns.0.x - m.columns.1.y)
            vector = SIMD4<Float>(
                (m.columns.2.x + m.columns.0.z) / s,
                (m.columns.2.y + m.columns.1.z) / s,
                0.25 * s,
                (m.columns.0.y - m.columns.1.x) / s
            )
        }
    }

    // Init from 4x4 rotation matrix (extracts upper-left 3x3)
    public init(_ m: simd_float4x4) { self.init(simd_float3x3(m)) }

    // Rotate a vector by this quaternion
    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let q = imag
        let t = 2.0 * simd_cross(q, v)
        return v + real * t + simd_cross(q, t)
    }
}

extension simd_quatf: Equatable {
    public static func == (lhs: simd_quatf, rhs: simd_quatf) -> Bool { lhs.vector == rhs.vector }
}

public func * (lhs: simd_quatf, rhs: simd_quatf) -> simd_quatf {
    let lv = lhs.vector, rv = rhs.vector
    return simd_quatf(vector: SIMD4<Float>(
        lv.w*rv.x + lv.x*rv.w + lv.y*rv.z - lv.z*rv.y,
        lv.w*rv.y - lv.x*rv.z + lv.y*rv.w + lv.z*rv.x,
        lv.w*rv.z + lv.x*rv.y - lv.y*rv.x + lv.z*rv.w,
        lv.w*rv.w - lv.x*rv.x - lv.y*rv.y - lv.z*rv.z
    ))
}

#endif
