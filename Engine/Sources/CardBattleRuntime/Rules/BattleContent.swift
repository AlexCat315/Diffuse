import Foundation

public struct BattleCard: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var cost: Int
    public var skillID: String?
    public var damage: Int
    public var effects: [BattleCardEffect]

    public init(id: String,
                title: String,
                cost: Int,
                skillID: String? = nil,
                damage: Int = 0,
                effects: [BattleCardEffect]? = nil) {
        self.id = id
        self.title = title
        self.cost = cost
        self.skillID = skillID
        self.damage = damage
        self.effects = effects ?? (damage > 0 ? [.damage(damage)] : [])
    }

    public var totalDamage: Int {
        effects.reduce(0) { total, effect in
            switch effect {
            case let .damage(amount):
                return total + amount
            case .heal, .block:
                return total
            }
        }
    }

    public var totalHealing: Int {
        effects.reduce(0) { total, effect in
            switch effect {
            case .damage:
                return total
            case let .heal(amount):
                return total + amount
            case .block:
                return total
            }
        }
    }

    public var totalBlock: Int {
        effects.reduce(0) { total, effect in
            switch effect {
            case .damage, .heal:
                return total
            case let .block(amount):
                return total + amount
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cost
        case skillID
        case damage
        case effects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let cost = try container.decode(Int.self, forKey: .cost)
        let skillID = try container.decodeIfPresent(String.self, forKey: .skillID)
        let damage = try container.decodeIfPresent(Int.self, forKey: .damage) ?? 0
        let effects = try container.decodeIfPresent([BattleCardEffect].self, forKey: .effects)
        self.init(id: id, title: title, cost: cost, skillID: skillID, damage: damage, effects: effects)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(cost, forKey: .cost)
        try container.encodeIfPresent(skillID, forKey: .skillID)
        try container.encode(damage, forKey: .damage)
        try container.encode(effects, forKey: .effects)
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
