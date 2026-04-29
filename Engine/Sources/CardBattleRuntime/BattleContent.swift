import Foundation

public struct BattleCard: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var cost: Int
    public var skillID: String?
    public var damage: Int

    public init(id: String, title: String, cost: Int, skillID: String? = nil, damage: Int = 0) {
        self.id = id
        self.title = title
        self.cost = cost
        self.skillID = skillID
        self.damage = damage
    }
}

public struct BattleSkill: Identifiable, Hashable, Sendable, Codable {
    public enum Target: String, Sendable, Codable {
        case selfSide
        case opponent
        case allEnemies
    }

    public var id: String
    public var title: String
    public var cooldownTurns: Int
    public var target: Target

    public init(id: String, title: String, cooldownTurns: Int = 0, target: Target) {
        self.id = id
        self.title = title
        self.cooldownTurns = cooldownTurns
        self.target = target
    }
}
