import Foundation

public enum BattleSampleFactory {
    public static func makeThreeKingdomsDuel() -> BattleState {
        let playerDeck = [
            BattleCard(id: "green-dragon", title: "Green Dragon", cost: 5, skillID: "cleave", damage: 18),
            BattleCard(id: "seven-strike", title: "Seven Strike", cost: 3, skillID: "slash", damage: 9),
            BattleCard(id: "fire-ambush", title: "Fire Ambush", cost: 4, skillID: "burn", damage: 14),
            BattleCard(id: "borrow-east", title: "Borrow East", cost: 2, skillID: "draw", effects: [.block(6)]),
        ]
        let player = BattlePlayerState(
            id: .player,
            health: 32_000,
            maxHealth: 32_000,
            maxEnergy: 10,
            deck: playerDeck,
            skills: [
                BattleSkill(id: "slash", title: "Slash", target: .opponent),
                BattleSkill(id: "rally", title: "Rally", cooldownTurns: 1, target: .selfSide),
                BattleSkill(id: "duel", title: "Duel", cooldownTurns: 2, target: .opponent),
            ]
        )
        let enemy = BattlePlayerState(
            id: .enemy,
            health: 32_000,
            maxHealth: 32_000,
            maxEnergy: 8,
            deck: [
                BattleCard(id: "halberd", title: "Halberd", cost: 3, damage: 10),
                BattleCard(id: "war-cry", title: "War Cry", cost: 2, damage: 0),
            ],
            skills: [
                BattleSkill(id: "counter", title: "Counter", target: .opponent)
            ]
        )
        return BattleState(players: [.player: player, .enemy: enemy])
    }
}
