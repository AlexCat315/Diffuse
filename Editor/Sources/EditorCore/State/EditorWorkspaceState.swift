import Foundation
import IntentRuntime

/// Owns the editor workspace state and its persistence defaults.
public struct EditorWorkspaceState: Codable, Sendable {
    public var mode: EditorWorkspaceMode = .level
    public var layoutPreset: EditorLayoutPreset = .levelDefault

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case layoutPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(EditorWorkspaceMode.self, forKey: .mode) ?? mode
        layoutPreset = try container.decodeIfPresent(EditorLayoutPreset.self, forKey: .layoutPreset) ?? layoutPreset
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(layoutPreset, forKey: .layoutPreset)
    }
}
