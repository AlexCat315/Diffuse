import Foundation
import SIMDCompat

public protocol SamplingStrategy: Sendable {
    func sample2D(_ index: Int, sample: Int) -> SIMD2<Float>
    var name: String { get }
}

public struct HaltonSampler: SamplingStrategy {
    public let name = "halton"

    public init() {}

    public func sample2D(_ index: Int, sample: Int) -> SIMD2<Float> {
        SIMD2<Float>(
            halton(index, base: 2),
            halton(index, base: 3)
        )
    }

    private func halton(_ index: Int, base: Int) -> Float {
        var result: Float = 0
        var f: Float = 1
        var i = index + 1
        while i > 0 {
            f /= Float(base)
            result += f * Float(i % base)
            i /= base
        }
        return result
    }
}

public struct BlueNoiseSampler: SamplingStrategy {
    public let name = "blue_noise"
    private let textureSize: Int

    public init(textureSize: Int = 64) {
        self.textureSize = textureSize
    }

    public func sample2D(_ index: Int, sample: Int) -> SIMD2<Float> {
        // Scrambled Sobol-style fallback; replace with precomputed
        // blue-noise texture lookup when available.
        let x = Float((index * 2654435761) & 0xFF) / 256.0
        let y = Float((sample * 2654435761) & 0xFF) / 256.0
        return SIMD2<Float>(x, y)
    }
}

public enum SamplingStrategyPreset: Sendable, CaseIterable {
    case halton
    case blueNoise

    public func create() -> any SamplingStrategy {
        switch self {
        case .halton:    return HaltonSampler()
        case .blueNoise: return BlueNoiseSampler()
        }
    }
}
