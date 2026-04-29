import Foundation

public struct BattlePlayerState: Sendable, Equatable, Codable {
    public var id: BattlePlayerID
    public var health: Int
    public var maxEnergy: Int
    public var energy: Int
    public var deck: [BattleCard]
    public var hand: [BattleCard]
    public var discard: [BattleCard]
    public var skills: [BattleSkill]

    public init(id: BattlePlayerID,
                health: Int,
                maxEnergy: Int,
                energy: Int = 0,
                deck: [BattleCard],
                hand: [BattleCard] = [],
                discard: [BattleCard] = [],
                skills: [BattleSkill] = []) {
        self.id = id
        self.health = health
        self.maxEnergy = maxEnergy
        self.energy = energy
        self.deck = deck
        self.hand = hand
        self.discard = discard
        self.skills = skills
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
