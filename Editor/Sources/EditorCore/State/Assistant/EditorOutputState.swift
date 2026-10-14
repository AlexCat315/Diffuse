import Foundation
import IntentRuntime

/// Console records are transient. Console selection is also session state.
public struct EditorOutputState: Codable, Sendable {
    public var consoleEntries: [EditorConsoleEntry] = []
    public var nextConsoleEntryID: UInt64 = 1
    public var outputTab: EditorOutputTab = .logs

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: CodingKey {}
    public init(from decoder: Decoder) throws {
        self.init()
        _ = try decoder.container(keyedBy: CodingKeys.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }

    mutating func normalize() {
        nextConsoleEntryID = max(nextConsoleEntryID, (consoleEntries.map(\.id).max() ?? 0) &+ 1)
    }
}
