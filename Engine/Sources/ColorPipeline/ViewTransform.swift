import Foundation
import SIMDCompat

public struct ViewTransform: Sendable {
    public let config: ACESConfig
    public let exposure: Float
    public let gamma: Float

    public init(
        config: ACESConfig = ACESConfig(),
        exposure: Float = 0,
        gamma: Float = 1
    ) {
        self.config = config
        self.exposure = exposure
        self.gamma = gamma
    }

    public func ocioDescription(bridge: OCIOBridge?) -> String {
        guard let bridge, bridge.isAvailable else {
            return "sRGB (passthrough 鈥?OCIO unavailable)"
        }
        let fromSpace = config.workingSpace.rawValue
        let toSpace = config.displayTransform.rawValue
        let vt = config.viewTransform.rawValue
        return "OCIO: \(fromSpace) 鈫?\(toSpace) [\(vt)] exp=\(exposure) gamma=\(gamma)"
    }

    public func apply(to pixels: inout [Float],
                      width: Int,
                      height: Int,
                      using bridge: OCIOBridge?) -> Bool {
        guard let bridge, bridge.isAvailable else {
            applyPassthroughGamma(to: &pixels)
            return false
        }
        return bridge.applyTransform(
            inputColorSpace: config.workingSpace.rawValue,
            outputColorSpace: config.displayTransform.rawValue,
            viewTransform: config.viewTransform.rawValue,
            exposure: exposure,
            gamma: gamma,
            to: &pixels,
            width: Int32(width),
            height: Int32(height)
        )
    }

    private func applyPassthroughGamma(to pixels: inout [Float]) {
        guard gamma != 1 else { return }
        let invGamma = 1 / max(0.001, gamma)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<min(3, pixels.count - i) {
                let v = max(0, pixels[i + c])
                pixels[i + c] = powf(v, invGamma)
            }
        }
    }
}
