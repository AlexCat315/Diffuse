import GuavaUICompose
import Foundation
import IntentRuntime

/// Owns the editor navigation state and its persistence defaults.
public struct EditorNavigationState: Codable, Sendable {
    public var activeAssetDrag: EditorAssetDragPayload? = nil
    public var commandPaletteVisible: Bool = false
    public var operations: [EditorOperation] = []
    public var scriptNavigation: EditorScriptNavigationRequest? = nil
    public var assetNavigationID: String? = nil
    public var assetNavigationRevision: UInt64 = 0
    public var commandPaletteQuery: TextBuffer = ""

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case activeAssetDrag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeAssetDrag = try container.decodeIfPresent(EditorAssetDragPayload.self, forKey: .activeAssetDrag)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(activeAssetDrag, forKey: .activeAssetDrag)
    }
}
