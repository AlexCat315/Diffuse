import Foundation

public enum BattleCommand: Sendable, Equatable {
    case startPlayerTurn(drawCount: Int)
    case playCard(cardID: String, target: BattlePlayerID)
    case endPlayerTurn
    case resolveEnemyAction(damage: Int)
}
