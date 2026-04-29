import CardBattleRuntime
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
}
