import Foundation
import IntentRuntime

/// Owns the editor selection state and its persistence defaults.
public struct EditorSelectionState: Codable, Sendable {
    public var selectedEntityID: UInt64? = nil
    public var selectedEntityIDs: Set<UInt64> = []
    public var primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract
    public var inspectorCollapsedSectionIDs: Set<String> = []
    public var inspectorSceneSettingsVisible: Bool = false

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case selectedEntityID
        case selectedEntityIDs
        case primarySelectBehavior
        case inspectorCollapsedSectionIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedEntityID = try container.decodeIfPresent(UInt64.self, forKey: .selectedEntityID)
        selectedEntityIDs =
            try container.decodeIfPresent(Set<UInt64>.self, forKey: .selectedEntityIDs) ?? selectedEntityIDs
        primarySelectBehavior =
            try container.decodeIfPresent(SelectionPrimaryModifierBehavior.self, forKey: .primarySelectBehavior)
            ?? primarySelectBehavior
        inspectorCollapsedSectionIDs =
            try container.decodeIfPresent(Set<String>.self, forKey: .inspectorCollapsedSectionIDs)
            ?? inspectorCollapsedSectionIDs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedEntityID, forKey: .selectedEntityID)
        try container.encode(selectedEntityIDs, forKey: .selectedEntityIDs)
        try container.encode(primarySelectBehavior, forKey: .primarySelectBehavior)
        try container.encode(inspectorCollapsedSectionIDs, forKey: .inspectorCollapsedSectionIDs)
    }
}
