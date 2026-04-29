import Foundation

public enum BattleCardEffect: Sendable, Equatable, Hashable, Codable {
    case damage(Int)
    case heal(Int)
}
