import Foundation
import IntentRuntime

/// Owns the editor document state and its persistence defaults.
public struct EditorDocumentState: Codable, Sendable {
    public var sceneRevision: UInt64 = 0
    public var lastSavedSceneRevision: UInt64 = 0
    public var sceneRecoveryPending: Bool = false
    public var pendingCloseRequest: EditorPendingCloseRequest? = nil

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case sceneRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneRevision = try container.decodeIfPresent(UInt64.self, forKey: .sceneRevision) ?? sceneRevision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sceneRevision, forKey: .sceneRevision)
    }
}
