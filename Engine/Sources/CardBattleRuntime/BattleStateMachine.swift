import Foundation

public enum BattleStateMachine {
    public static func reduce(_ state: BattleState, command: BattleCommand) -> BattleState {
        reduceWithResult(state, command: command).state
    }

    public static func reduceWithResult(_ state: BattleState, command: BattleCommand) -> BattleReductionResult {
        var next = state
        var events: [BattleEvent] = []
        var rejection: BattleCommandRejection?
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
            events.append(.turnStarted(turn: next.turn, playerID: .player, cardsDrawn: drawCount))
        case let .playCard(cardID, target):
            rejection = playCard(cardID: cardID, target: target, state: &next, events: &events)
        case .endPlayerTurn:
            rejection = endPlayerTurn(state: &next, events: &events)
        case let .resolveEnemyAction(damage):
            rejection = resolveEnemyAction(damage: damage, state: &next, events: &events)
        }
        if let rejection {
            events.append(.commandRejected(rejection))
        }
        return BattleReductionResult(state: next, events: events, rejection: rejection)
    }

    private static func drawCards(for playerID: BattlePlayerID, count: Int, state: inout BattleState) {
        guard count > 0, var player = state.players[playerID] else { return }
        for _ in 0..<count {
            guard !player.deck.isEmpty else { break }
            player.hand.append(player.deck.removeFirst())
        }
        state.players[playerID] = player
    }

    private static func playCard(cardID: String,
                                 target: BattlePlayerID,
                                 state: inout BattleState,
                                 events: inout [BattleEvent]) -> BattleCommandRejection? {
        guard state.phase == .main else {
            state.log.append("cannot play \(cardID)")
            return .invalidPhase(expected: .main, actual: state.phase)
        }
        guard var player = state.players[state.activePlayerID] else {
            state.log.append("cannot play \(cardID)")
            return .missingPlayer(state.activePlayerID)
        }
        guard let cardIndex = player.hand.firstIndex(where: { $0.id == cardID }) else {
            state.log.append("cannot play \(cardID)")
            return .missingCard(cardID: cardID)
        }

        let card = player.hand[cardIndex]
        guard player.energy >= card.cost else {
            state.log.append("not enough energy for \(card.id)")
            return .insufficientEnergy(cardID: card.id, available: player.energy, required: card.cost)
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
            events.append(.cardPlayed(playerID: player.id, cardID: card.id, targetID: target, damage: card.damage))
            if targetPlayer.health == 0 {
                state.phase = target == .enemy ? .victory : .defeat
                events.append(.playerDefeated(target))
                return nil
            }
        } else {
            state.log.append("\(player.id.rawValue) played \(card.id)")
            events.append(.cardPlayed(playerID: player.id, cardID: card.id, targetID: target, damage: 0))
        }
        state.phase = .main
        return nil
    }

    private static func endPlayerTurn(state: inout BattleState,
                                      events: inout [BattleEvent]) -> BattleCommandRejection? {
        guard state.phase == .main else {
            state.log.append("cannot end player turn")
            return .invalidPhase(expected: .main, actual: state.phase)
        }
        guard state.activePlayerID == .player else {
            state.log.append("cannot end player turn")
            return .inactivePlayer(expected: .player, actual: state.activePlayerID)
        }
        guard var player = state.players[.player] else {
            state.log.append("cannot end player turn")
            return .missingPlayer(.player)
        }

        player.discard.append(contentsOf: player.hand)
        player.hand.removeAll(keepingCapacity: true)
        player.energy = 0
        state.players[.player] = player
        state.activePlayerID = .enemy
        state.phase = .enemyTurn
        state.log.append("turn \(state.turn): player ended turn")
        events.append(.turnEnded(turn: state.turn, playerID: .player))
        return nil
    }

    private static func resolveEnemyAction(damage: Int,
                                           state: inout BattleState,
                                           events: inout [BattleEvent]) -> BattleCommandRejection? {
        guard state.phase == .enemyTurn else {
            state.log.append("cannot resolve enemy action")
            return .invalidPhase(expected: .enemyTurn, actual: state.phase)
        }
        guard state.activePlayerID == .enemy else {
            state.log.append("cannot resolve enemy action")
            return .inactivePlayer(expected: .enemy, actual: state.activePlayerID)
        }

        if damage > 0, var player = state.players[.player] {
            player.health = max(0, player.health - damage)
            state.players[.player] = player
            state.log.append("enemy dealt \(damage) damage")
            events.append(.enemyActionResolved(damage: damage))
            if player.health == 0 {
                state.phase = .defeat
                events.append(.playerDefeated(.player))
                return nil
            }
        } else {
            state.log.append("enemy waited")
            events.append(.enemyActionResolved(damage: 0))
        }
        state.activePlayerID = .player
        state.phase = .draw
        return nil
    }
}
