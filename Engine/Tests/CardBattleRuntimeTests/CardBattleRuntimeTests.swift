import CardBattleRuntime
import Testing

@Suite("CardBattleRuntime")
struct CardBattleRuntimeTests {
    @Test("starting player turn refreshes energy and draws into hand")
    func startPlayerTurnDrawsCards() {
        let strike = BattleCard(id: "strike", title: "Strike", cost: 1, skillID: "slash")
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
}
