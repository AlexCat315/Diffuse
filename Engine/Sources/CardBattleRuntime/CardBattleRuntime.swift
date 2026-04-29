import Foundation

public struct BattlePlayerID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let player = BattlePlayerID(rawValue: "player")
    public static let enemy = BattlePlayerID(rawValue: "enemy")
}

public struct BattleCard: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var cost: Int
    public var skillID: String?

    public init(id: String, title: String, cost: Int, skillID: String? = nil) {
        self.id = id
        self.title = title
        self.cost = cost
        self.skillID = skillID
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

public enum BattleCommand: Sendable, Equatable {
    case startPlayerTurn(drawCount: Int)
}

public enum BattleStateMachine {
    public static func reduce(_ state: BattleState, command: BattleCommand) -> BattleState {
        var next = state
        switch command {
        case let .startPlayerTurn(drawCount):
            next.turn += 1
            next.phase = .draw
            next.activePlayerID = .player
            if var player = next.players[.player] {
                player.energy = player.maxEnergy
                next.players[.player] = player
            }
            drawCards(for: .player, count: drawCount, state: &next)
            next.phase = .main
            next.log.append("turn \(next.turn): player drew \(drawCount) card(s)")
        }
        return next
    }

    private static func drawCards(for playerID: BattlePlayerID, count: Int, state: inout BattleState) {
        guard count > 0, var player = state.players[playerID] else { return }
        for _ in 0..<count {
            guard !player.deck.isEmpty else { break }
            player.hand.append(player.deck.removeFirst())
        }
        state.players[playerID] = player
    }
}
