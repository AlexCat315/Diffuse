//! `BattleValidationIssue` and `BattleStateValidator`.

use serde::{Deserialize, Serialize};

use crate::core::battle_state::BattleState;
use crate::rules::battle_content::BattleCard;
use crate::rules::battle_effect::BattleCardEffect;
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleValidationIssue`.
///
/// Associated-value cases encode as `{"caseName": {"label": value}}` and single
/// unlabelled payloads as `{"caseName": {"_0": value}}` (MIGRATION.md §5.4).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BattleValidationIssue {
    #[serde(rename = "missingActivePlayer")]
    MissingActivePlayer {
        #[serde(rename = "_0")]
        player_id: BattlePlayerID,
    },
    #[serde(rename = "mismatchedPlayerKey")]
    MismatchedPlayerKey {
        expected: BattlePlayerID,
        actual: BattlePlayerID,
    },
    #[serde(rename = "negativeHealth")]
    NegativeHealth {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        health: i64,
    },
    #[serde(rename = "negativeMaxHealth")]
    NegativeMaxHealth {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "maxHealth")]
        max_health: i64,
    },
    #[serde(rename = "healthExceedsMaximum")]
    HealthExceedsMaximum {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        health: i64,
        #[serde(rename = "maxHealth")]
        max_health: i64,
    },
    #[serde(rename = "negativeBlock")]
    NegativeBlock {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        block: i64,
    },
    #[serde(rename = "negativeMaxEnergy")]
    NegativeMaxEnergy {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "maxEnergy")]
        max_energy: i64,
    },
    #[serde(rename = "negativeEnergy")]
    NegativeEnergy {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        energy: i64,
    },
    #[serde(rename = "energyExceedsMaximum")]
    EnergyExceedsMaximum {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        energy: i64,
        #[serde(rename = "maxEnergy")]
        max_energy: i64,
    },
    #[serde(rename = "negativeCardCost")]
    NegativeCardCost {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "cardID")]
        card_id: String,
        cost: i64,
    },
    #[serde(rename = "negativeCardDamage")]
    NegativeCardDamage {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "cardID")]
        card_id: String,
        damage: i64,
    },
    #[serde(rename = "negativeCardHealing")]
    NegativeCardHealing {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "cardID")]
        card_id: String,
        healing: i64,
    },
    #[serde(rename = "negativeCardBlock")]
    NegativeCardBlock {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "cardID")]
        card_id: String,
        block: i64,
    },
    #[serde(rename = "negativeSkillCooldown")]
    NegativeSkillCooldown {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "skillID")]
        skill_id: String,
        #[serde(rename = "cooldownTurns")]
        cooldown_turns: i64,
    },
}

/// `BattleStateValidator`.
pub struct BattleStateValidator;

impl BattleStateValidator {
    /// `validate(_:)`. Issues are reported in Swift's order: the active-player
    /// check first, then each player in map order with its piles and skills.
    pub fn validate(state: &BattleState) -> Vec<BattleValidationIssue> {
        let mut issues: Vec<BattleValidationIssue> = Vec::new();
        if !state.players.contains_key(&state.active_player_id) {
            issues.push(BattleValidationIssue::MissingActivePlayer {
                player_id: state.active_player_id.clone(),
            });
        }

        for (player_id, player) in &state.players {
            if player.id != *player_id {
                issues.push(BattleValidationIssue::MismatchedPlayerKey {
                    expected: player_id.clone(),
                    actual: player.id.clone(),
                });
            }
            if player.health < 0 {
                issues.push(BattleValidationIssue::NegativeHealth {
                    player_id: player_id.clone(),
                    health: player.health,
                });
            }
            if player.max_health < 0 {
                issues.push(BattleValidationIssue::NegativeMaxHealth {
                    player_id: player_id.clone(),
                    max_health: player.max_health,
                });
            }
            if player.health > player.max_health {
                issues.push(BattleValidationIssue::HealthExceedsMaximum {
                    player_id: player_id.clone(),
                    health: player.health,
                    max_health: player.max_health,
                });
            }
            if player.block < 0 {
                issues.push(BattleValidationIssue::NegativeBlock {
                    player_id: player_id.clone(),
                    block: player.block,
                });
            }
            if player.max_energy < 0 {
                issues.push(BattleValidationIssue::NegativeMaxEnergy {
                    player_id: player_id.clone(),
                    max_energy: player.max_energy,
                });
            }
            if player.energy < 0 {
                issues.push(BattleValidationIssue::NegativeEnergy {
                    player_id: player_id.clone(),
                    energy: player.energy,
                });
            }
            if player.energy > player.max_energy {
                issues.push(BattleValidationIssue::EnergyExceedsMaximum {
                    player_id: player_id.clone(),
                    energy: player.energy,
                    max_energy: player.max_energy,
                });
            }
            BattleStateValidator::validate_cards(&player.deck, player_id, &mut issues);
            BattleStateValidator::validate_cards(&player.hand, player_id, &mut issues);
            BattleStateValidator::validate_cards(&player.discard, player_id, &mut issues);
            for skill in &player.skills {
                if skill.cooldown_turns < 0 {
                    issues.push(BattleValidationIssue::NegativeSkillCooldown {
                        player_id: player_id.clone(),
                        skill_id: skill.id.clone(),
                        cooldown_turns: skill.cooldown_turns,
                    });
                }
            }
        }

        issues
    }

    fn validate_cards(
        cards: &[BattleCard],
        player_id: &BattlePlayerID,
        issues: &mut Vec<BattleValidationIssue>,
    ) {
        for card in cards {
            if card.cost < 0 {
                issues.push(BattleValidationIssue::NegativeCardCost {
                    player_id: player_id.clone(),
                    card_id: card.id.clone(),
                    cost: card.cost,
                });
            }
            if card.damage < 0 {
                issues.push(BattleValidationIssue::NegativeCardDamage {
                    player_id: player_id.clone(),
                    card_id: card.id.clone(),
                    damage: card.damage,
                });
            }
            for effect in &card.effects {
                match effect {
                    BattleCardEffect::Damage { amount } if *amount < 0 => {
                        issues.push(BattleValidationIssue::NegativeCardDamage {
                            player_id: player_id.clone(),
                            card_id: card.id.clone(),
                            damage: *amount,
                        });
                    }
                    BattleCardEffect::Heal { amount } if *amount < 0 => {
                        issues.push(BattleValidationIssue::NegativeCardHealing {
                            player_id: player_id.clone(),
                            card_id: card.id.clone(),
                            healing: *amount,
                        });
                    }
                    BattleCardEffect::Block { amount } if *amount < 0 => {
                        issues.push(BattleValidationIssue::NegativeCardBlock {
                            player_id: player_id.clone(),
                            card_id: card.id.clone(),
                            block: *amount,
                        });
                    }
                    BattleCardEffect::Damage { .. }
                    | BattleCardEffect::Heal { .. }
                    | BattleCardEffect::Block { .. } => {}
                }
            }
        }
    }
}
