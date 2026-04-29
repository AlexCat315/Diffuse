import CardBattleRuntime
import Foundation
import Testing

@Suite("CardBattleRuntime")
struct CardBattleRuntimeTests {
    @Test("starting player turn refreshes energy and draws into hand")
    func startPlayerTurnDrawsCards() {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, skillID: "slash", damage: 6)
        let guardCard = BattleCard(id: "guard", title: "Guard", cost: 1)
        let player = BattlePlayerState(
            id: .player,
            health: 32,
            maxEnergy: 3,
            deck: [strike, guardCard],
            skills: [BattleSkill(id: "slash", title: "Slash", target: .opponent)]
        )
        let enemy = BattlePlayerState(id: .enemy, health: 28, maxEnergy: 2, deck: [])
        let initial = BattleState(players: [.player: player, .enemy: enemy])

        let next = BattleStateMachine.reduce(initial, command: .startPlayerTurn(drawCount: 2))

        #expect(next.turn == 1)
        #expect(next.phase == .main)
        #expect(next.activePlayerID == .player)
        #expect(next.players[.player]?.energy == 3)
        #expect(next.players[.player]?.hand.map(\.id) == ["strike", "guard"])
        #expect(next.players[.player]?.deck.isEmpty == true)
        #expect(next.log == ["turn 1: player drew 2 card(s)"])
    }

    @Test("starting turn reports actual drawn count when deck is short")
    func startPlayerTurnReportsActualDrawnCount() {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, damage: 6)
        let player = BattlePlayerState(id: .player, health: 32, maxEnergy: 3, deck: [strike])
        let initial = BattleState(players: [.player: player])

        let result = BattleStateMachine.reduceWithResult(initial, command: .startPlayerTurn(drawCount: 3))

        #expect(result.state.players[.player]?.hand.map(\.id) == ["strike"])
        #expect(result.state.log == ["turn 1: player drew 1 card(s)"])
        #expect(result.events == [.turnStarted(turn: 1, playerID: .player, cardsDrawn: 1)])
    }

    @Test("starting a turn supports any battle player")
    func startTurnSupportsAnyPlayer() {
        let enemyCard = BattleCard(id: "counter", title: "Counter", cost: 1, damage: 4)
        let enemy = BattlePlayerState(id: .enemy, health: 24, maxEnergy: 2, deck: [enemyCard])
        let initial = BattleState(players: [.enemy: enemy])

        let result = BattleStateMachine.reduceWithResult(
            initial,
            command: .startTurn(playerID: .enemy, drawCount: 1)
        )

        #expect(result.state.turn == 1)
        #expect(result.state.activePlayerID == .enemy)
        #expect(result.state.players[.enemy]?.energy == 2)
        #expect(result.state.players[.enemy]?.hand.map(\.id) == ["counter"])
        #expect(result.events == [.turnStarted(turn: 1, playerID: .enemy, cardsDrawn: 1)])
    }

    @Test("playing a card spends energy moves it to discard and damages target")
    func playCardResolvesDamage() {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, skillID: "slash", damage: 6)
        let player = BattlePlayerState(
            id: .player,
            health: 32,
            maxEnergy: 3,
            energy: 2,
            deck: [],
            hand: [strike]
        )
        let enemy = BattlePlayerState(id: .enemy, health: 6, maxEnergy: 2, deck: [])
        let initial = BattleState(
            phase: .main,
            turn: 1,
            activePlayerID: .player,
            players: [.player: player, .enemy: enemy]
        )

        let next = BattleStateMachine.reduce(initial, command: .playCard(cardID: "strike", target: .enemy))

        #expect(next.phase == .victory)
        #expect(next.players[.player]?.energy == 1)
        #expect(next.players[.player]?.hand.isEmpty == true)
        #expect(next.players[.player]?.discard.map(\.id) == ["strike"])
        #expect(next.players[.enemy]?.health == 0)
        #expect(next.log == ["player played strike for 6 damage"])
    }

    @Test("reducer exposes structured events and rejections")
    func reducerExposesStructuredResult() {
        let finisher = BattleCard(id: "finisher", title: "Finisher", cost: 4, damage: 18)
        let player = BattlePlayerState(
            id: .player,
            health: 32,
            maxEnergy: 3,
            energy: 1,
            deck: [],
            hand: [finisher]
        )
        let enemy = BattlePlayerState(id: .enemy, health: 24, maxEnergy: 2, deck: [])
        let state = BattleState(
            phase: .main,
            turn: 1,
            activePlayerID: .player,
            players: [.player: player, .enemy: enemy]
        )

        let result = BattleStateMachine.reduceWithResult(
            state,
            command: .playCard(cardID: "finisher", target: .enemy)
        )

        #expect(result.state.players[.player]?.energy == 1)
        #expect(result.rejection == .insufficientEnergy(cardID: "finisher", available: 1, required: 4))
        #expect(result.events == [
            .commandRejected(.insufficientEnergy(cardID: "finisher", available: 1, required: 4))
        ])
        #expect(result.state.log == ["not enough energy for finisher"])
    }

    @Test("battle commands are codable for replay and networking")
    func battleCommandsAreCodable() throws {
        let command = BattleCommand.playCard(cardID: "strike", target: .enemy)

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(BattleCommand.self, from: data)

        #expect(decoded == command)
    }

    @Test("hud snapshot projects playable hand and skills for ui")
    func hudSnapshotProjectsHandAndSkills() throws {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, skillID: "slash", damage: 6)
        let finisher = BattleCard(id: "finisher", title: "Finisher", cost: 4, damage: 18)
        let player = BattlePlayerState(
            id: .player,
            health: 32,
            maxEnergy: 3,
            energy: 2,
            deck: [],
            hand: [strike, finisher],
            skills: [
                BattleSkill(id: "slash", title: "Slash", target: .opponent),
                BattleSkill(id: "duel", title: "Duel", cooldownTurns: 2, target: .opponent),
            ]
        )
        let state = BattleState(
            phase: .main,
            turn: 2,
            activePlayerID: .player,
            players: [
                .player: player,
                .enemy: BattlePlayerState(id: .enemy, health: 24, maxEnergy: 2, deck: [])
            ]
        )

        let snapshot = try #require(BattleHUDSnapshot.make(from: state, playerID: .player))

        #expect(snapshot.phase == .main)
        #expect(snapshot.turn == 2)
        #expect(snapshot.energy == 2)
        #expect(snapshot.health == 32)
        #expect(snapshot.opponentHealth == 24)
        #expect(snapshot.hand.map(\.id) == ["strike", "finisher"])
        #expect(snapshot.hand.map(\.isPlayable) == [true, false])
        #expect(snapshot.skills == [
            BattleSkillViewModel(id: "slash", title: "Slash", target: .opponent, isEnabled: true),
            BattleSkillViewModel(id: "duel", title: "Duel", cooldownTurns: 2, target: .opponent, isEnabled: false),
        ])
    }

    @Test("battle rules expose shared command availability")
    func battleRulesExposeCommandAvailability() {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, damage: 6)
        let finisher = BattleCard(id: "finisher", title: "Finisher", cost: 4, damage: 18)
        let player = BattlePlayerState(
            id: .player,
            health: 32,
            maxEnergy: 3,
            energy: 2,
            deck: [],
            hand: [strike, finisher]
        )
        let enemy = BattlePlayerState(id: .enemy, health: 24, maxEnergy: 2, deck: [])
        let state = BattleState(
            phase: .main,
            turn: 1,
            activePlayerID: .player,
            players: [.player: player, .enemy: enemy]
        )

        #expect(BattleRules.opponent(of: .player, in: state) == .enemy)
        #expect(BattleRules.canPlayCards(in: state, playerID: .player))
        #expect(BattleRules.canPlay(strike, for: .player, in: state))
        #expect(BattleRules.canPlay(finisher, for: .player, in: state) == false)
        #expect(BattleRules.canEndTurn(state, playerID: .player))
        #expect(BattleRules.canResolveEnemyAction(state) == false)
    }

    @Test("ending player turn discards hand and passes control to enemy")
    func endPlayerTurnDiscardsHand() {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, damage: 6)
        let guardCard = BattleCard(id: "guard", title: "Guard", cost: 1)
        let player = BattlePlayerState(
            id: .player,
            health: 32,
            maxEnergy: 3,
            energy: 2,
            deck: [],
            hand: [strike, guardCard]
        )
        let state = BattleState(
            phase: .main,
            turn: 2,
            activePlayerID: .player,
            players: [.player: player]
        )

        let next = BattleStateMachine.reduce(state, command: .endPlayerTurn)

        #expect(next.phase == .enemyTurn)
        #expect(next.activePlayerID == .enemy)
        #expect(next.players[.player]?.energy == 0)
        #expect(next.players[.player]?.hand.isEmpty == true)
        #expect(next.players[.player]?.discard.map(\.id) == ["strike", "guard"])
        #expect(next.log == ["turn 2: player ended turn"])
    }

    @Test("enemy action damages player and returns to player draw phase")
    func enemyActionReturnsToPlayerDraw() {
        let player = BattlePlayerState(id: .player, health: 32, maxEnergy: 3, deck: [])
        let enemy = BattlePlayerState(id: .enemy, health: 24, maxEnergy: 2, deck: [])
        let state = BattleState(
            phase: .enemyTurn,
            turn: 2,
            activePlayerID: .enemy,
            players: [.player: player, .enemy: enemy]
        )

        let next = BattleStateMachine.reduce(state, command: .resolveEnemyAction(damage: 5))

        #expect(next.phase == .draw)
        #expect(next.activePlayerID == .player)
        #expect(next.players[.player]?.health == 27)
        #expect(next.log == ["enemy dealt 5 damage"])
    }

    @Test("sample factory creates playable duel state")
    func sampleFactoryCreatesDuel() {
        let initial = BattleSampleFactory.makeThreeKingdomsDuel()
        let turn = BattleStateMachine.reduce(initial, command: .startPlayerTurn(drawCount: 3))
        let snapshot = BattleHUDSnapshot.make(from: turn, playerID: .player)

        #expect(initial.players[.player]?.deck.count == 4)
        #expect(initial.players[.enemy]?.health == 32_000)
        #expect(snapshot?.hand.count == 3)
        #expect(snapshot?.skills.map(\.id) == ["slash", "rally", "duel"])
    }

    @Test("state validator reports invalid battle data")
    func validatorReportsInvalidBattleData() {
        let badCard = BattleCard(id: "bad-card", title: "Bad Card", cost: -1, damage: -4)
        let player = BattlePlayerState(
            id: .enemy,
            health: -10,
            maxEnergy: 2,
            energy: 3,
            deck: [badCard],
            skills: [BattleSkill(id: "bad-skill", title: "Bad Skill", cooldownTurns: -1, target: .opponent)]
        )
        let state = BattleState(
            activePlayerID: .player,
            players: [.enemy: player]
        )

        let issues = BattleStateValidator.validate(state)

        #expect(issues.contains(.missingActivePlayer(.player)))
        #expect(issues.contains(.mismatchedPlayerKey(expected: .enemy, actual: .enemy)) == false)
        #expect(issues.contains(.negativeHealth(playerID: .enemy, health: -10)))
        #expect(issues.contains(.energyExceedsMaximum(playerID: .enemy, energy: 3, maxEnergy: 2)))
        #expect(issues.contains(.negativeCardCost(playerID: .enemy, cardID: "bad-card", cost: -1)))
        #expect(issues.contains(.negativeCardDamage(playerID: .enemy, cardID: "bad-card", damage: -4)))
        #expect(issues.contains(.negativeSkillCooldown(
            playerID: .enemy,
            skillID: "bad-skill",
            cooldownTurns: -1
        )))
    }
}
