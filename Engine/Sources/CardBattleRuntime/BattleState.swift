import Foundation

public struct BattlePlayerState: Sendable, Equatable, Codable {
    public var id: BattlePlayerID
    public var health: Int
    public var maxHealth: Int
    public var block: Int
    public var maxEnergy: Int
    public var energy: Int
    public var deck: [BattleCard]
    public var hand: [BattleCard]
    public var discard: [BattleCard]
    public var skills: [BattleSkill]

    public init(id: BattlePlayerID,
                health: Int,
                maxHealth: Int? = nil,
                block: Int = 0,
                maxEnergy: Int,
                energy: Int = 0,
                deck: [BattleCard],
                hand: [BattleCard] = [],
                discard: [BattleCard] = [],
                skills: [BattleSkill] = []) {
        self.id = id
        self.health = health
        self.maxHealth = maxHealth ?? health
        self.block = block
        self.maxEnergy = maxEnergy
        self.energy = energy
        self.deck = deck
        self.hand = hand
        self.discard = discard
        self.skills = skills
    }

    enum CodingKeys: String, CodingKey {
        case id
        case health
        case maxHealth
        case block
        case maxEnergy
        case energy
        case deck
        case hand
        case discard
        case skills
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(BattlePlayerID.self, forKey: .id)
        let health = try container.decode(Int.self, forKey: .health)
        let maxHealth = try container.decodeIfPresent(Int.self, forKey: .maxHealth)
        let block = try container.decodeIfPresent(Int.self, forKey: .block) ?? 0
        let maxEnergy = try container.decode(Int.self, forKey: .maxEnergy)
        let energy = try container.decodeIfPresent(Int.self, forKey: .energy) ?? 0
        let deck = try container.decode([BattleCard].self, forKey: .deck)
        let hand = try container.decodeIfPresent([BattleCard].self, forKey: .hand) ?? []
        let discard = try container.decodeIfPresent([BattleCard].self, forKey: .discard) ?? []
        let skills = try container.decodeIfPresent([BattleSkill].self, forKey: .skills) ?? []
        self.init(
            id: id,
            health: health,
            maxHealth: maxHealth,
            block: block,
            maxEnergy: maxEnergy,
            energy: energy,
            deck: deck,
            hand: hand,
            discard: discard,
            skills: skills
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(health, forKey: .health)
        try container.encode(maxHealth, forKey: .maxHealth)
        try container.encode(block, forKey: .block)
        try container.encode(maxEnergy, forKey: .maxEnergy)
        try container.encode(energy, forKey: .energy)
        try container.encode(deck, forKey: .deck)
        try container.encode(hand, forKey: .hand)
        try container.encode(discard, forKey: .discard)
        try container.encode(skills, forKey: .skills)
    }
}

public enum BattlePhase: String, Sendable, Equatable, Codable {
    case setup
    case draw
    case main
    case resolvingCard
    case enemyTurn
    case victory
    case defeat
}

public struct BattleState: Sendable, Equatable, Codable {
    public var phase: BattlePhase
    public var turn: Int
    public var activePlayerID: BattlePlayerID
    public var players: [BattlePlayerID: BattlePlayerState]
    public var log: [String]

    public init(phase: BattlePhase = .setup,
                turn: Int = 0,
                activePlayerID: BattlePlayerID = .player,
                players: [BattlePlayerID: BattlePlayerState],
                log: [String] = []) {
        self.phase = phase
        self.turn = turn
        self.activePlayerID = activePlayerID
        self.players = players
        self.log = log
    }
}
