import Foundation
import IntentRuntime

/// Owns the editor window state and its persistence defaults.
public struct EditorWindowState: Codable, Sendable {
    public var focused: Bool = true
    public var minimized: Bool = false
    public var occluded: Bool = false

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case focused
        case minimized
        case occluded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? focused
        minimized = try container.decodeIfPresent(Bool.self, forKey: .minimized) ?? minimized
        occluded = try container.decodeIfPresent(Bool.self, forKey: .occluded) ?? occluded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(focused, forKey: .focused)
        try container.encode(minimized, forKey: .minimized)
        try container.encode(occluded, forKey: .occluded)
    }
}
