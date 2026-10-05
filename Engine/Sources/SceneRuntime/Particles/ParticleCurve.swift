import EngineKernel
import SIMDCompat

public struct ParticleCurveKeyframe: Codable, Sendable, Equatable, Hashable {
    public var time: Float
    public var value: Float

    public init(time: Float, value: Float) {
        self.time = simd_clamp(time, 0, 1)
        self.value = value
    }
}

public enum ParticleCurve: RawRepresentable, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case constant(Float)
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case keyframes([ParticleCurveKeyframe])

    public typealias RawValue = String

    public static var allCases: [ParticleCurve] {
        [.constant(1), .linear, .easeIn, .easeOut, .easeInOut]
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "constant":
            self = .constant(1)
        case "linear":
            self = .linear
        case "easeIn":
            self = .easeIn
        case "easeOut":
            self = .easeOut
        case "easeInOut":
            self = .easeInOut
        case "keyframes":
            self = .keyframes([])
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .constant:
            return "constant"
        case .linear:
            return "linear"
        case .easeIn:
            return "easeIn"
        case .easeOut:
            return "easeOut"
        case .easeInOut:
            return "easeInOut"
        case .keyframes:
            return "keyframes"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case keyframes
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawValue = try? container.decode(String.self),
           let curve = ParticleCurve(rawValue: rawValue) {
            self = curve
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "linear"
        if type == "constant" {
            self = .constant(try container.decodeIfPresent(Float.self, forKey: .value) ?? 1)
        } else if type == "keyframes" {
            self = .keyframes(try container.decodeIfPresent([ParticleCurveKeyframe].self,
                                                            forKey: .keyframes) ?? [])
        } else {
            self = ParticleCurve(rawValue: type) ?? .linear
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .constant(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rawValue, forKey: .type)
            try container.encode(value, forKey: .value)
        case .linear, .easeIn, .easeOut, .easeInOut:
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        case .keyframes(let keyframes):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rawValue, forKey: .type)
            try container.encode(keyframes, forKey: .keyframes)
        }
    }

    public func evaluate(at t: Float) -> Float {
        let x = simd_clamp(t, 0, 1)
        switch self {
        case .constant(let value):
            return value
        case .linear:
            return x
        case .easeIn:
            return x * x
        case .easeOut:
            return 1 - (1 - x) * (1 - x)
        case .easeInOut:
            if x < 0.5 { return 2 * x * x }
            let inverse = 1 - x
            return 1 - 2 * inverse * inverse
        case .keyframes(let keyframes):
            return Self.evaluateKeyframes(keyframes, at: x)
        }
    }

    public func conservativeValueRange() -> (min: Float, max: Float) {
        switch self {
        case .constant(let value):
            return (value, value)
        case .linear, .easeIn, .easeOut, .easeInOut:
            return (0, 1)
        case .keyframes(let keyframes):
            guard !keyframes.isEmpty else { return (0, 1) }
            var minimum = keyframes[0].value
            var maximum = keyframes[0].value
            for keyframe in keyframes.dropFirst() {
                minimum = min(minimum, keyframe.value)
                maximum = max(maximum, keyframe.value)
            }
            return (minimum, maximum)
        }
    }

    private static func evaluateKeyframes(_ keyframes: [ParticleCurveKeyframe], at t: Float) -> Float {
        guard !keyframes.isEmpty else { return t }
        let sorted = keyframes.enumerated()
            .sorted {
                if $0.element.time == $1.element.time {
                    return $0.offset < $1.offset
                }
                return $0.element.time < $1.element.time
            }
            .map(\.element)
        guard let first = sorted.first else { return t }
        guard let last = sorted.last else { return first.value }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }

        for index in 1..<sorted.count {
            let lower = sorted[index - 1]
            let upper = sorted[index]
            guard t <= upper.time else { continue }
            let span = upper.time - lower.time
            guard span > 0.0001 else { return upper.value }
            let localT = (t - lower.time) / span
            return lower.value + (upper.value - lower.value) * localT
        }
        return last.value
    }
}
