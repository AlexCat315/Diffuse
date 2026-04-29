import Foundation

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
    public var opponentHealth: Int
    public var hand: [BattleHandCardViewModel]
    public var skills: [BattleSkillViewModel]

    public init(phase: BattlePhase,
                turn: Int,
                energy: Int,
                maxEnergy: Int,
                health: Int,
                opponentHealth: Int,
                hand: [BattleHandCardViewModel],
                skills: [BattleSkillViewModel]) {
        self.phase = phase
        self.turn = turn
        self.energy = energy
        self.maxEnergy = maxEnergy
        self.health = health
        self.opponentHealth = opponentHealth
        self.hand = hand
        self.skills = skills
    }

    public static func make(from state: BattleState, playerID: BattlePlayerID) -> BattleHUDSnapshot? {
        guard let player = state.players[playerID] else { return nil }
        let canPlayCards = state.phase == .main && state.activePlayerID == playerID
        let opponentID: BattlePlayerID = playerID == .player ? .enemy : .player
        return BattleHUDSnapshot(
            phase: state.phase,
            turn: state.turn,
            energy: player.energy,
            maxEnergy: player.maxEnergy,
            health: player.health,
            opponentHealth: state.players[opponentID]?.health ?? 0,
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
