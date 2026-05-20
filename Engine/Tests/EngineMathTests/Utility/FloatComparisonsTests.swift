import EngineMath
import SIMDCompat
import Testing

@Suite("FloatComparisons")
struct FloatComparisonsTests {
    @Test("nearlyEqual compares scalars and vectors with tolerance")
    func nearlyEqualComparesScalarsAndVectors() {
        #expect(FloatComparisons.nearlyEqual(1, 1.000_000_4))
        #expect(!FloatComparisons.nearlyEqual(1, 1.01))
        #expect(FloatComparisons.nearlyEqual(
            SIMD3<Float>(1, 2, 3),
            SIMD3<Float>(1.000_000_4, 2, 2.999_999_8)
        ))
    }
}
