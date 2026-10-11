import Foundation

public enum FontWeight: Hashable, Sendable {
    case regular
    case medium
    case semibold
    case bold


}

public struct Font: Hashable, Sendable {
    public enum Design: Hashable, Sendable { case standard, monospaced }
    public let size: Float
    public let weight: FontWeight
    public let design: Design
    /// nil uses the host's primary family (or its monospaced family).
    public let family: String?

    public init(size: Float, weight: FontWeight = .regular, design: Design = .standard, family: String? = nil) {
        self.size = max(1, size)
        self.weight = weight
        self.design = design
        self.family = family
    }

    public static func system(size: Float, weight: FontWeight = .regular) -> Font {
        Font(size: size, weight: weight)
    }

    public static func named(_ family: String, size: Float, weight: FontWeight = .regular) -> Font {
        Font(size: size, weight: weight, family: family)
    }

    public static func monospaced(size: Float, weight: FontWeight = .regular) -> Font {
        Font(size: size, weight: weight, design: .monospaced)
    }
}
