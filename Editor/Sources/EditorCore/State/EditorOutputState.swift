import Foundation
import IntentRuntime

/// Owns the editor output state and its persistence defaults.
public struct EditorOutputState: Codable, Sendable {
    public var consoleEntries: [EditorConsoleEntry] = []
    public var nextConsoleEntryID: UInt64 = 1
    public var outputTab: EditorOutputTab = .logs

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case consoleEntries
        case nextConsoleEntryID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        consoleEntries =
            try container.decodeIfPresent([EditorConsoleEntry].self, forKey: .consoleEntries) ?? consoleEntries
        nextConsoleEntryID =
            try container.decodeIfPresent(UInt64.self, forKey: .nextConsoleEntryID) ?? nextConsoleEntryID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(consoleEntries, forKey: .consoleEntries)
        try container.encode(nextConsoleEntryID, forKey: .nextConsoleEntryID)
    }

    mutating func normalize() {
        nextConsoleEntryID = max(nextConsoleEntryID, (consoleEntries.map(\.id).max() ?? 0) &+ 1)
    }
}
