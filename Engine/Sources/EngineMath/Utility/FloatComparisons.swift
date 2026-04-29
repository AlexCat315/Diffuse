import simd

public enum FloatComparisons {
    public static func nearlyEqual(_ lhs: Float,
                                   _ rhs: Float,
                                   tolerance: Float = 0.000_001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    public static func nearlyEqual(_ lhs: SIMD3<Float>,
                                   _ rhs: SIMD3<Float>,
                                   tolerance: Float = 0.000_001) -> Bool {
        nearlyEqual(lhs.x, rhs.x, tolerance: tolerance)
            && nearlyEqual(lhs.y, rhs.y, tolerance: tolerance)
            && nearlyEqual(lhs.z, rhs.z, tolerance: tolerance)
    }
}
