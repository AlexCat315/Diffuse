import Foundation

public enum BattleCommandRejection: Sendable, Equatable, Codable {
    case invalidPhase(expected: BattlePhase, actual: BattlePhase)
    case inactivePlayer(expected: BattlePlayerID, actual: BattlePlayerID)
    case missingPlayer(BattlePlayerID)
    case missingCard(cardID: String)
    case insufficientEnergy(cardID: String, available: Int, required: Int)
}

public enum BattleEvent: Sendable, Equatable, Codable {
    case turnStarted(turn: Int, playerID: BattlePlayerID, cardsDrawn: Int)
    case cardPlayed(playerID: BattlePlayerID, cardID: String, targetID: BattlePlayerID, damage: Int)
    case healthRestored(playerID: BattlePlayerID, amount: Int)
    case blockGained(playerID: BattlePlayerID, amount: Int)
    case turnEnded(turn: Int, playerID: BattlePlayerID)
    case enemyActionResolved(damage: Int)
    case playerDefeated(BattlePlayerID)
    case commandRejected(BattleCommandRejection)
}

public struct BattleReductionResult: Sendable, Equatable, Codable {
    public var state: BattleState
    public var events: [BattleEvent]
    public var rejection: BattleCommandRejection?

    public init(state: BattleState,
                events: [BattleEvent] = [],
                rejection: BattleCommandRejection? = nil) {
        self.state = state
        self.events = events
        self.rejection = rejection
    }
}
