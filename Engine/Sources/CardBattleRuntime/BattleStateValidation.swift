import Foundation

public enum BattleValidationIssue: Sendable, Equatable, Codable {
    case missingActivePlayer(BattlePlayerID)
    case mismatchedPlayerKey(expected: BattlePlayerID, actual: BattlePlayerID)
    case negativeHealth(playerID: BattlePlayerID, health: Int)
    case negativeMaxHealth(playerID: BattlePlayerID, maxHealth: Int)
    case healthExceedsMaximum(playerID: BattlePlayerID, health: Int, maxHealth: Int)
    case negativeMaxEnergy(playerID: BattlePlayerID, maxEnergy: Int)
    case negativeEnergy(playerID: BattlePlayerID, energy: Int)
    case energyExceedsMaximum(playerID: BattlePlayerID, energy: Int, maxEnergy: Int)
    case negativeCardCost(playerID: BattlePlayerID, cardID: String, cost: Int)
    case negativeCardDamage(playerID: BattlePlayerID, cardID: String, damage: Int)
    case negativeCardHealing(playerID: BattlePlayerID, cardID: String, healing: Int)
    case negativeCardBlock(playerID: BattlePlayerID, cardID: String, block: Int)
    case negativeSkillCooldown(playerID: BattlePlayerID, skillID: String, cooldownTurns: Int)
}

public enum BattleStateValidator {
    public static func validate(_ state: BattleState) -> [BattleValidationIssue] {
        var issues: [BattleValidationIssue] = []
        if state.players[state.activePlayerID] == nil {
            issues.append(.missingActivePlayer(state.activePlayerID))
        }

        for (playerID, player) in state.players {
            if player.id != playerID {
                issues.append(.mismatchedPlayerKey(expected: playerID, actual: player.id))
            }
            if player.health < 0 {
                issues.append(.negativeHealth(playerID: playerID, health: player.health))
            }
            if player.maxHealth < 0 {
                issues.append(.negativeMaxHealth(playerID: playerID, maxHealth: player.maxHealth))
            }
            if player.health > player.maxHealth {
                issues.append(.healthExceedsMaximum(
                    playerID: playerID,
                    health: player.health,
                    maxHealth: player.maxHealth
                ))
            }
            if player.maxEnergy < 0 {
                issues.append(.negativeMaxEnergy(playerID: playerID, maxEnergy: player.maxEnergy))
            }
            if player.energy < 0 {
                issues.append(.negativeEnergy(playerID: playerID, energy: player.energy))
            }
            if player.energy > player.maxEnergy {
                issues.append(.energyExceedsMaximum(
                    playerID: playerID,
                    energy: player.energy,
                    maxEnergy: player.maxEnergy
                ))
            }
            validateCards(player.deck, owner: playerID, issues: &issues)
            validateCards(player.hand, owner: playerID, issues: &issues)
            validateCards(player.discard, owner: playerID, issues: &issues)
            for skill in player.skills where skill.cooldownTurns < 0 {
                issues.append(.negativeSkillCooldown(
                    playerID: playerID,
                    skillID: skill.id,
                    cooldownTurns: skill.cooldownTurns
                ))
            }
        }

        return issues
    }

    private static func validateCards(_ cards: [BattleCard],
                                      owner playerID: BattlePlayerID,
                                      issues: inout [BattleValidationIssue]) {
        for card in cards {
            if card.cost < 0 {
                issues.append(.negativeCardCost(playerID: playerID, cardID: card.id, cost: card.cost))
            }
            if card.damage < 0 {
                issues.append(.negativeCardDamage(playerID: playerID, cardID: card.id, damage: card.damage))
            }
            for effect in card.effects {
                switch effect {
                case let .damage(amount) where amount < 0:
                    issues.append(.negativeCardDamage(playerID: playerID, cardID: card.id, damage: amount))
                case let .heal(amount) where amount < 0:
                    issues.append(.negativeCardHealing(playerID: playerID, cardID: card.id, healing: amount))
                case let .block(amount) where amount < 0:
                    issues.append(.negativeCardBlock(playerID: playerID, cardID: card.id, block: amount))
                case .damage:
                    break
                case .heal:
                    break
                case .block:
                    break
                }
            }
        }
    }
}
