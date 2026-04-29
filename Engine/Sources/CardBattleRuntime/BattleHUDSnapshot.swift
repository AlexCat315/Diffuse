import Foundation

public struct BattleHandCardViewModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var cost: Int
    public var isPlayable: Bool
    public var damage: Int
    public var healing: Int

    public init(id: String,
                title: String,
                cost: Int,
                isPlayable: Bool,
                damage: Int,
                healing: Int = 0) {
        self.id = id
        self.title = title
        self.cost = cost
        self.isPlayable = isPlayable
        self.damage = damage
        self.healing = healing
    }
}

public struct BattleSkillViewModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var cooldownTurns: Int
    public var target: BattleSkill.Target
    public var isEnabled: Bool

    public init(id: String,
                title: String,
                cooldownTurns: Int = 0,
                target: BattleSkill.Target,
                isEnabled: Bool) {
        self.id = id
        self.title = title
        self.cooldownTurns = cooldownTurns
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
    public var maxHealth: Int
    public var opponentHealth: Int
    public var opponentMaxHealth: Int
    public var hand: [BattleHandCardViewModel]
    public var skills: [BattleSkillViewModel]

    public init(phase: BattlePhase,
                turn: Int,
                energy: Int,
                maxEnergy: Int,
                health: Int,
                maxHealth: Int,
                opponentHealth: Int,
                opponentMaxHealth: Int,
                hand: [BattleHandCardViewModel],
                skills: [BattleSkillViewModel]) {
        self.phase = phase
        self.turn = turn
        self.energy = energy
        self.maxEnergy = maxEnergy
        self.health = health
        self.maxHealth = maxHealth
        self.opponentHealth = opponentHealth
        self.opponentMaxHealth = opponentMaxHealth
        self.hand = hand
        self.skills = skills
    }

    public static func make(from state: BattleState, playerID: BattlePlayerID) -> BattleHUDSnapshot? {
        guard let player = state.players[playerID] else { return nil }
        let canPlayCards = BattleRules.canPlayCards(in: state, playerID: playerID)
        let opponentID = BattleRules.opponent(of: playerID, in: state)
        return BattleHUDSnapshot(
            phase: state.phase,
            turn: state.turn,
            energy: player.energy,
            maxEnergy: player.maxEnergy,
            health: player.health,
            maxHealth: player.maxHealth,
            opponentHealth: opponentID.flatMap { state.players[$0]?.health } ?? 0,
            opponentMaxHealth: opponentID.flatMap { state.players[$0]?.maxHealth } ?? 0,
            hand: player.hand.map {
                BattleHandCardViewModel(
                    id: $0.id,
                    title: $0.title,
                    cost: $0.cost,
                    isPlayable: canPlayCards && BattleRules.canPlay($0, for: playerID, in: state),
                    damage: $0.totalDamage,
                    healing: $0.totalHealing
                )
            },
            skills: player.skills.map {
                BattleSkillViewModel(
                    id: $0.id,
                    title: $0.title,
                    cooldownTurns: $0.cooldownTurns,
                    target: $0.target,
                    isEnabled: canPlayCards && $0.cooldownTurns == 0
                )
            }
        )
    }
}
