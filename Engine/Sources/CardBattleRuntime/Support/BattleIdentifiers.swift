import Foundation

public struct BattlePlayerID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let player = BattlePlayerID(rawValue: "player")
    public static let enemy = BattlePlayerID(rawValue: "enemy")
}
