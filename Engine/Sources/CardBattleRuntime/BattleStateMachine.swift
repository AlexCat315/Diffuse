import Foundation

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
        case let .resolveEnemyAction(damage):
            resolveEnemyAction(damage: damage, state: &next)
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

    private static func resolveEnemyAction(damage: Int, state: inout BattleState) {
        guard state.phase == .enemyTurn,
              state.activePlayerID == .enemy
        else {
            state.log.append("cannot resolve enemy action")
            return
        }

        if damage > 0, var player = state.players[.player] {
            player.health = max(0, player.health - damage)
            state.players[.player] = player
            state.log.append("enemy dealt \(damage) damage")
            if player.health == 0 {
                state.phase = .defeat
                return
            }
        } else {
            state.log.append("enemy waited")
        }
        state.activePlayerID = .player
        state.phase = .draw
    }
}
