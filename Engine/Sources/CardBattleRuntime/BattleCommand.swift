import Foundation

public enum BattleCommand: Sendable, Equatable, Codable {
    case startTurn(playerID: BattlePlayerID, drawCount: Int)
    case startPlayerTurn(drawCount: Int)
    case playCard(cardID: String, target: BattlePlayerID)
    case endTurn(playerID: BattlePlayerID)
    case endPlayerTurn
    case resolveEnemyAction(damage: Int)
}
