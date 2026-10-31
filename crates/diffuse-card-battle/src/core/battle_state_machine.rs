//! `BattleStateMachine` — the pure command reducer.

use crate::core::battle_reduction::{BattleCommandRejection, BattleEvent, BattleReductionResult};
use crate::core::battle_state::{BattlePhase, BattlePlayerState, BattleState};
use crate::rules::battle_command::BattleCommand;
use crate::rules::battle_rules::BattleRules;
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleStateMachine`.
pub struct BattleStateMachine;

impl BattleStateMachine {
    /// `reduce(_:command:)` — the state after applying `command`.
    pub fn reduce(state: &BattleState, command: &BattleCommand) -> BattleState {
        BattleStateMachine::reduce_with_result(state, command).state
    }

    /// `reduceWithResult(_:command:)`.
    pub fn reduce_with_result(
        state: &BattleState,
        command: &BattleCommand,
    ) -> BattleReductionResult {
        let mut next = state.clone();
        let mut events: Vec<BattleEvent> = Vec::new();
        let rejection = match command {
            BattleCommand::StartTurn {
                player_id,
                draw_count,
            } => BattleStateMachine::start_turn(player_id, *draw_count, &mut next, &mut events),
            BattleCommand::StartPlayerTurn { draw_count } => BattleStateMachine::start_turn(
                &BattlePlayerID::player(),
                *draw_count,
                &mut next,
                &mut events,
            ),
            BattleCommand::PlayCard { card_id, target } => {
                BattleStateMachine::play_card(card_id, target, &mut next, &mut events)
            }
            BattleCommand::EndTurn { player_id } => {
                BattleStateMachine::end_turn(player_id, &mut next, &mut events)
            }
            BattleCommand::EndPlayerTurn {} => {
                BattleStateMachine::end_turn(&BattlePlayerID::player(), &mut next, &mut events)
            }
            BattleCommand::ResolveEnemyAction { damage } => {
                BattleStateMachine::resolve_enemy_action(*damage, &mut next, &mut events)
            }
        };
        if let Some(rejection) = &rejection {
            events.push(BattleEvent::CommandRejected {
                rejection: rejection.clone(),
            });
        }
        BattleReductionResult::new(next, events, rejection)
    }

    fn start_turn(
        player_id: &BattlePlayerID,
        draw_count: i64,
        state: &mut BattleState,
        events: &mut Vec<BattleEvent>,
    ) -> Option<BattleCommandRejection> {
        let Some(mut player) = state.players.get(player_id).cloned() else {
            return Some(BattleCommandRejection::MissingPlayer {
                player_id: player_id.clone(),
            });
        };

        state.turn += 1;
        state.phase = BattlePhase::Draw;
        state.active_player_id = player_id.clone();
        player.block = 0;
        player.energy = player.max_energy;
        state.players.insert(player_id.clone(), player);
        let drawn_count = BattleStateMachine::draw_cards(player_id, draw_count, state);
        state.phase = BattlePhase::Main;
        state.log.push(format!(
            "turn {}: {} drew {} card(s)",
            state.turn, player_id.raw_value, drawn_count
        ));
        events.push(BattleEvent::TurnStarted {
            turn: state.turn,
            player_id: player_id.clone(),
            cards_drawn: drawn_count,
        });
        None
    }

    fn draw_cards(player_id: &BattlePlayerID, count: i64, state: &mut BattleState) -> i64 {
        if count <= 0 {
            return 0;
        }
        let Some(mut player) = state.players.get(player_id).cloned() else {
            return 0;
        };
        let mut drawn_count = 0;
        for _ in 0..count {
            if player.deck.is_empty() {
                break;
            }
            player.hand.push(player.deck.remove(0));
            drawn_count += 1;
        }
        state.players.insert(player_id.clone(), player);
        drawn_count
    }

    fn play_card(
        card_id: &str,
        target: &BattlePlayerID,
        state: &mut BattleState,
        events: &mut Vec<BattleEvent>,
    ) -> Option<BattleCommandRejection> {
        if state.phase != BattlePhase::Main {
            state.log.push(format!("cannot play {card_id}"));
            return Some(BattleCommandRejection::InvalidPhase {
                expected: BattlePhase::Main,
                actual: state.phase,
            });
        }
        let Some(mut player) = state.players.get(&state.active_player_id).cloned() else {
            state.log.push(format!("cannot play {card_id}"));
            return Some(BattleCommandRejection::MissingPlayer {
                player_id: state.active_player_id.clone(),
            });
        };
        let Some(card_index) = player.hand.iter().position(|card| card.id == card_id) else {
            state.log.push(format!("cannot play {card_id}"));
            return Some(BattleCommandRejection::MissingCard {
                card_id: card_id.to_string(),
            });
        };

        let card = player.hand[card_index].clone();
        if player.energy < card.cost {
            state.log.push(format!("not enough energy for {}", card.id));
            return Some(BattleCommandRejection::InsufficientEnergy {
                card_id: card.id,
                available: player.energy,
                required: card.cost,
            });
        }

        state.phase = BattlePhase::ResolvingCard;
        player.energy -= card.cost;
        player.hand.remove(card_index);
        player.discard.push(card.clone());
        state.players.insert(player.id.clone(), player.clone());

        let damage = card.total_damage();
        let healing = card.total_healing();
        let block = card.total_block();
        let mut did_apply_effect = false;
        if damage > 0
            && let Some(mut target_player) = state.players.get(target).cloned()
        {
            let resolved_damage = BattleStateMachine::apply_damage(damage, &mut target_player);
            state.players.insert(target.clone(), target_player.clone());
            if resolved_damage.blocked > 0 {
                state.log.push(format!(
                    "{} played {} for {} damage ({} blocked)",
                    player.id.raw_value, card.id, resolved_damage.dealt, resolved_damage.blocked
                ));
            } else {
                state.log.push(format!(
                    "{} played {} for {} damage",
                    player.id.raw_value, card.id, resolved_damage.dealt
                ));
            }
            events.push(BattleEvent::CardPlayed {
                player_id: player.id.clone(),
                card_id: card.id.clone(),
                target_id: target.clone(),
                damage: resolved_damage.dealt,
            });
            did_apply_effect = true;
            if target_player.health == 0 {
                state.phase = if *target == BattlePlayerID::enemy() {
                    BattlePhase::Victory
                } else {
                    BattlePhase::Defeat
                };
                events.push(BattleEvent::PlayerDefeated {
                    player_id: target.clone(),
                });
                return None;
            }
        }
        if healing > 0
            && let Some(mut target_player) = state.players.get(target).cloned()
        {
            let restored = healing.min(0.max(target_player.max_health - target_player.health));
            target_player.health += restored;
            state.players.insert(target.clone(), target_player);
            state.log.push(format!(
                "{} played {} for {} healing",
                player.id.raw_value, card.id, restored
            ));
            events.push(BattleEvent::HealthRestored {
                player_id: target.clone(),
                amount: restored,
            });
            did_apply_effect = true;
        }
        if block > 0
            && let Some(mut target_player) = state.players.get(target).cloned()
        {
            target_player.block += block;
            state.players.insert(target.clone(), target_player);
            state.log.push(format!(
                "{} played {} for {} block",
                player.id.raw_value, card.id, block
            ));
            events.push(BattleEvent::BlockGained {
                player_id: target.clone(),
                amount: block,
            });
            did_apply_effect = true;
        }
        if !did_apply_effect {
            state
                .log
                .push(format!("{} played {}", player.id.raw_value, card.id));
            events.push(BattleEvent::CardPlayed {
                player_id: player.id.clone(),
                card_id: card.id.clone(),
                target_id: target.clone(),
                damage: 0,
            });
        }
        state.phase = BattlePhase::Main;
        None
    }

    fn end_turn(
        player_id: &BattlePlayerID,
        state: &mut BattleState,
        events: &mut Vec<BattleEvent>,
    ) -> Option<BattleCommandRejection> {
        if state.phase != BattlePhase::Main {
            state
                .log
                .push(format!("cannot end {} turn", player_id.raw_value));
            return Some(BattleCommandRejection::InvalidPhase {
                expected: BattlePhase::Main,
                actual: state.phase,
            });
        }
        if state.active_player_id != *player_id {
            state
                .log
                .push(format!("cannot end {} turn", player_id.raw_value));
            return Some(BattleCommandRejection::InactivePlayer {
                expected: player_id.clone(),
                actual: state.active_player_id.clone(),
            });
        }
        let Some(mut player) = state.players.get(player_id).cloned() else {
            state
                .log
                .push(format!("cannot end {} turn", player_id.raw_value));
            return Some(BattleCommandRejection::MissingPlayer {
                player_id: player_id.clone(),
            });
        };

        player.discard.append(&mut player.hand);
        player.hand.clear();
        player.energy = 0;
        state.players.insert(player_id.clone(), player);
        state.active_player_id = BattleRules::opponent(player_id, state)
            .unwrap_or_else(|| BattleStateMachine::default_opponent(player_id));
        state.phase = if *player_id == BattlePlayerID::player() {
            BattlePhase::EnemyTurn
        } else {
            BattlePhase::Draw
        };
        state.log.push(format!(
            "turn {}: {} ended turn",
            state.turn, player_id.raw_value
        ));
        events.push(BattleEvent::TurnEnded {
            turn: state.turn,
            player_id: player_id.clone(),
        });
        None
    }

    fn default_opponent(player_id: &BattlePlayerID) -> BattlePlayerID {
        if *player_id == BattlePlayerID::player() {
            BattlePlayerID::enemy()
        } else {
            BattlePlayerID::player()
        }
    }

    fn resolve_enemy_action(
        damage: i64,
        state: &mut BattleState,
        events: &mut Vec<BattleEvent>,
    ) -> Option<BattleCommandRejection> {
        if state.phase != BattlePhase::EnemyTurn {
            state.log.push("cannot resolve enemy action".to_string());
            return Some(BattleCommandRejection::InvalidPhase {
                expected: BattlePhase::EnemyTurn,
                actual: state.phase,
            });
        }
        if state.active_player_id != BattlePlayerID::enemy() {
            state.log.push("cannot resolve enemy action".to_string());
            return Some(BattleCommandRejection::InactivePlayer {
                expected: BattlePlayerID::enemy(),
                actual: state.active_player_id.clone(),
            });
        }

        let player_id = BattlePlayerID::player();
        if damage > 0
            && let Some(mut player) = state.players.get(&player_id).cloned()
        {
            let resolved_damage = BattleStateMachine::apply_damage(damage, &mut player);
            state.players.insert(player_id, player.clone());
            if resolved_damage.blocked > 0 {
                state.log.push(format!(
                    "enemy dealt {} damage ({} blocked)",
                    resolved_damage.dealt, resolved_damage.blocked
                ));
            } else {
                state
                    .log
                    .push(format!("enemy dealt {} damage", resolved_damage.dealt));
            }
            events.push(BattleEvent::EnemyActionResolved {
                damage: resolved_damage.dealt,
            });
            if player.health == 0 {
                state.phase = BattlePhase::Defeat;
                events.push(BattleEvent::PlayerDefeated {
                    player_id: BattlePlayerID::player(),
                });
                return None;
            }
        } else {
            state.log.push("enemy waited".to_string());
            events.push(BattleEvent::EnemyActionResolved { damage: 0 });
        }
        state.active_player_id = BattlePlayerID::player();
        state.phase = BattlePhase::Draw;
        None
    }

    fn apply_damage(amount: i64, player: &mut BattlePlayerState) -> DamageResolution {
        let blocked = player.block.min(amount);
        player.block -= blocked;
        let dealt = 0.max(amount - blocked);
        player.health = 0.max(player.health - dealt);
        DamageResolution { dealt, blocked }
    }
}

/// The `(dealt:blocked:)` tuple `applyDamage` returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DamageResolution {
    pub dealt: i64,
    pub blocked: i64,
}
