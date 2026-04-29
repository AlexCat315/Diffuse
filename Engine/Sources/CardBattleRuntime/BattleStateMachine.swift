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
        case let .startTurn(playerID, drawCount):
            rejection = startTurn(playerID: playerID, drawCount: drawCount, state: &next, events: &events)
        case let .startPlayerTurn(drawCount):
            rejection = startTurn(playerID: .player, drawCount: drawCount, state: &next, events: &events)
        case let .playCard(cardID, target):
            rejection = playCard(cardID: cardID, target: target, state: &next, events: &events)
        case let .endTurn(playerID):
            rejection = endTurn(playerID: playerID, state: &next, events: &events)
        case .endPlayerTurn:
            rejection = endTurn(playerID: .player, state: &next, events: &events)
        case let .resolveEnemyAction(damage):
            rejection = resolveEnemyAction(damage: damage, state: &next, events: &events)
        }
        if let rejection {
            events.append(.commandRejected(rejection))
        }
        return BattleReductionResult(state: next, events: events, rejection: rejection)
    }

    private static func startTurn(playerID: BattlePlayerID,
                                  drawCount: Int,
                                  state: inout BattleState,
                                  events: inout [BattleEvent]) -> BattleCommandRejection? {
        guard var player = state.players[playerID] else {
            return .missingPlayer(playerID)
        }

        state.turn += 1
        state.phase = .draw
        state.activePlayerID = playerID
        player.energy = player.maxEnergy
        state.players[playerID] = player
        let drawnCount = drawCards(for: playerID, count: drawCount, state: &state)
        state.phase = .main
        state.log.append("turn \(state.turn): \(playerID.rawValue) drew \(drawnCount) card(s)")
        events.append(.turnStarted(turn: state.turn, playerID: playerID, cardsDrawn: drawnCount))
        return nil
    }

    private static func drawCards(for playerID: BattlePlayerID, count: Int, state: inout BattleState) -> Int {
        guard count > 0, var player = state.players[playerID] else { return 0 }
        var drawnCount = 0
        for _ in 0..<count {
            guard !player.deck.isEmpty else { break }
            player.hand.append(player.deck.removeFirst())
            drawnCount += 1
        }
        state.players[playerID] = player
        return drawnCount
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

        let damage = card.totalDamage
        if damage > 0, var targetPlayer = state.players[target] {
            targetPlayer.health = max(0, targetPlayer.health - damage)
            state.players[target] = targetPlayer
            state.log.append("\(player.id.rawValue) played \(card.id) for \(damage) damage")
            events.append(.cardPlayed(playerID: player.id, cardID: card.id, targetID: target, damage: damage))
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

    private static func endTurn(playerID: BattlePlayerID,
                                state: inout BattleState,
                                events: inout [BattleEvent]) -> BattleCommandRejection? {
        guard state.phase == .main else {
            state.log.append("cannot end \(playerID.rawValue) turn")
            return .invalidPhase(expected: .main, actual: state.phase)
        }
        guard state.activePlayerID == playerID else {
            state.log.append("cannot end \(playerID.rawValue) turn")
            return .inactivePlayer(expected: playerID, actual: state.activePlayerID)
        }
        guard var player = state.players[playerID] else {
            state.log.append("cannot end \(playerID.rawValue) turn")
            return .missingPlayer(playerID)
        }

        player.discard.append(contentsOf: player.hand)
        player.hand.removeAll(keepingCapacity: true)
        player.energy = 0
        state.players[playerID] = player
        state.activePlayerID = BattleRules.opponent(of: playerID, in: state) ?? defaultOpponent(of: playerID)
        state.phase = playerID == .player ? .enemyTurn : .draw
        state.log.append("turn \(state.turn): \(playerID.rawValue) ended turn")
        events.append(.turnEnded(turn: state.turn, playerID: playerID))
        return nil
    }

    private static func defaultOpponent(of playerID: BattlePlayerID) -> BattlePlayerID {
        playerID == .player ? .enemy : .player
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
