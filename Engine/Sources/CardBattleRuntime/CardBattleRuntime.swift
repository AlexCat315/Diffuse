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
    case playCard(cardID: String, target: BattlePlayerID)
    case endPlayerTurn
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
        case let .playCard(cardID, target):
            playCard(cardID: cardID, target: target, state: &next)
        case .endPlayerTurn:
            endPlayerTurn(state: &next)
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

    private static func playCard(cardID: String, target: BattlePlayerID, state: inout BattleState) {
        guard state.phase == .main,
              var player = state.players[state.activePlayerID],
              let cardIndex = player.hand.firstIndex(where: { $0.id == cardID })
        else {
            state.log.append("cannot play \(cardID)")
            return
        }

        let card = player.hand[cardIndex]
        guard player.energy >= card.cost else {
            state.log.append("not enough energy for \(card.id)")
            return
        }

        state.phase = .resolvingCard
        player.energy -= card.cost
        player.hand.remove(at: cardIndex)
        player.discard.append(card)
        state.players[player.id] = player

        if card.damage > 0, var targetPlayer = state.players[target] {
            targetPlayer.health = max(0, targetPlayer.health - card.damage)
            state.players[target] = targetPlayer
            state.log.append("\(player.id.rawValue) played \(card.id) for \(card.damage) damage")
            if targetPlayer.health == 0 {
                state.phase = target == .enemy ? .victory : .defeat
                return
            }
        } else {
            state.log.append("\(player.id.rawValue) played \(card.id)")
        }
        state.phase = .main
    }

    private static func endPlayerTurn(state: inout BattleState) {
        guard state.phase == .main,
              state.activePlayerID == .player,
              var player = state.players[.player]
        else {
            state.log.append("cannot end player turn")
            return
        }

        player.discard.append(contentsOf: player.hand)
        player.hand.removeAll(keepingCapacity: true)
        player.energy = 0
        state.players[.player] = player
        state.activePlayerID = .enemy
        state.phase = .enemyTurn
        state.log.append("turn \(state.turn): player ended turn")
    }
}

public struct BattleHandCardViewModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var cost: Int
    public var isPlayable: Bool
    public var damage: Int

    public init(id: String, title: String, cost: Int, isPlayable: Bool, damage: Int) {
        self.id = id
        self.title = title
        self.cost = cost
        self.isPlayable = isPlayable
        self.damage = damage
    }
}

public struct BattleSkillViewModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var target: BattleSkill.Target
    public var isEnabled: Bool

    public init(id: String, title: String, target: BattleSkill.Target, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.target = target
        self.isEnabled = isEnabled
    }
}

public struct BattleHUDSnapshot: Sendable, Equatable {
    public var phase: BattlePhase
    public var turn: Int
    public var energy: Int
    public var maxEnergy: Int
    public var health: Int
    public var hand: [BattleHandCardViewModel]
    public var skills: [BattleSkillViewModel]

    public init(phase: BattlePhase,
                turn: Int,
                energy: Int,
                maxEnergy: Int,
                health: Int,
                hand: [BattleHandCardViewModel],
                skills: [BattleSkillViewModel]) {
        self.phase = phase
        self.turn = turn
        self.energy = energy
        self.maxEnergy = maxEnergy
        self.health = health
        self.hand = hand
        self.skills = skills
    }

    public static func make(from state: BattleState, playerID: BattlePlayerID) -> BattleHUDSnapshot? {
        guard let player = state.players[playerID] else { return nil }
        let canPlayCards = state.phase == .main && state.activePlayerID == playerID
        return BattleHUDSnapshot(
            phase: state.phase,
            turn: state.turn,
            energy: player.energy,
            maxEnergy: player.maxEnergy,
            health: player.health,
            hand: player.hand.map {
                BattleHandCardViewModel(
                    id: $0.id,
                    title: $0.title,
                    cost: $0.cost,
                    isPlayable: canPlayCards && player.energy >= $0.cost,
                    damage: $0.damage
                )
            },
            skills: player.skills.map {
                BattleSkillViewModel(
                    id: $0.id,
                    title: $0.title,
                    target: $0.target,
                    isEnabled: canPlayCards
                )
            }
        )
    }
}
