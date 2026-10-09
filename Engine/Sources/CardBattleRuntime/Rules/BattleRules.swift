import Foundation

public enum BattleRules {
    public static func opponent(of playerID: BattlePlayerID, in state: BattleState) -> BattlePlayerID? {
        if playerID == .player, state.players[.enemy] != nil {
            return .enemy
        }
        if playerID == .enemy, state.players[.player] != nil {
            return .player
        }
        return state.players.keys.first { $0 != playerID }
    }

    public static func canPlayCards(in state: BattleState, playerID: BattlePlayerID) -> Bool {
        state.phase == .main && state.activePlayerID == playerID
    }

    public static func canPlay(_ card: BattleCard, for playerID: BattlePlayerID, in state: BattleState) -> Bool {
        guard canPlayCards(in: state, playerID: playerID),
              let player = state.players[playerID]
        else { return false }
        return player.energy >= card.cost
    }

    public static func canEndTurn(_ state: BattleState, playerID: BattlePlayerID) -> Bool {
        state.phase == .main && state.activePlayerID == playerID
    }

    public static func canResolveEnemyAction(_ state: BattleState) -> Bool {
        state.phase == .enemyTurn && state.activePlayerID == .enemy
    }
}
