import Foundation
import IntentRuntime

/// Owns the editor workspace state and its persistence defaults.
public struct EditorWorkspaceState: Codable, Sendable, Equatable {
    public var mode: EditorWorkspaceMode = .level
    public var interactionMode: EditorInteractionMode = .manual
    public var layoutPreset: EditorLayoutPreset = .levelDefault

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
        normalize()
    }

    private mutating func normalize() {
        if layoutPreset.mode != mode { layoutPreset = .default(for: mode) }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case interactionMode
        case layoutPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(EditorWorkspaceMode.self, forKey: .mode) ?? mode
        interactionMode = try container.decodeIfPresent(EditorInteractionMode.self, forKey: .interactionMode) ?? interactionMode
        layoutPreset = try container.decodeIfPresent(EditorLayoutPreset.self, forKey: .layoutPreset) ?? layoutPreset
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encode(layoutPreset, forKey: .layoutPreset)
    }
}
