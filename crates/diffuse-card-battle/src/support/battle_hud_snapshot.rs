//! `BattleHUDSnapshot` and its hand/skill view models.

use crate::core::battle_state::{BattlePhase, BattleState};
use crate::rules::battle_content::BattleSkillTarget;
use crate::rules::battle_rules::BattleRules;
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleHandCardViewModel`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BattleHandCardViewModel {
    pub id: String,
    pub title: String,
    pub cost: i64,
    pub is_playable: bool,
    pub damage: i64,
    pub healing: i64,
    pub block: i64,
}

impl BattleHandCardViewModel {
    /// The Swift initialiser with its defaulted `healing` and `block`.
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        cost: i64,
        is_playable: bool,
        damage: i64,
        healing: i64,
        block: i64,
    ) -> Self {
        BattleHandCardViewModel {
            id: id.into(),
            title: title.into(),
            cost,
            is_playable,
            damage,
            healing,
            block,
        }
    }
}

/// `BattleSkillViewModel`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BattleSkillViewModel {
    pub id: String,
    pub title: String,
    pub cooldown_turns: i64,
    pub target: BattleSkillTarget,
    pub is_enabled: bool,
}

impl BattleSkillViewModel {
    /// The Swift initialiser with its defaulted `cooldownTurns`.
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        cooldown_turns: i64,
        target: BattleSkillTarget,
        is_enabled: bool,
    ) -> Self {
        BattleSkillViewModel {
            id: id.into(),
            title: title.into(),
            cooldown_turns,
            target,
            is_enabled,
        }
    }
}

/// `BattleHUDSnapshot`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BattleHUDSnapshot {
    pub phase: BattlePhase,
    pub turn: i64,
    pub energy: i64,
    pub max_energy: i64,
    pub health: i64,
    pub max_health: i64,
    pub block: i64,
    pub opponent_health: i64,
    pub opponent_max_health: i64,
    pub opponent_block: i64,
    pub deck_count: i64,
    pub discard_count: i64,
    pub hand: Vec<BattleHandCardViewModel>,
    pub skills: Vec<BattleSkillViewModel>,
}

impl BattleHUDSnapshot {
    /// The Swift initialiser. `block`, `opponentBlock`, `deckCount` and
    /// `discardCount` default to zero.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        phase: BattlePhase,
        turn: i64,
        energy: i64,
        max_energy: i64,
        health: i64,
        max_health: i64,
        block: i64,
        opponent_health: i64,
        opponent_max_health: i64,
        opponent_block: i64,
        deck_count: i64,
        discard_count: i64,
        hand: Vec<BattleHandCardViewModel>,
        skills: Vec<BattleSkillViewModel>,
    ) -> Self {
        BattleHUDSnapshot {
            phase,
            turn,
            energy,
            max_energy,
            health,
            max_health,
            block,
            opponent_health,
            opponent_max_health,
            opponent_block,
            deck_count,
            discard_count,
            hand,
            skills,
        }
    }

    /// `make(from:playerID:)` — `None` when the state has no such player.
    pub fn make(state: &BattleState, player_id: &BattlePlayerID) -> Option<Self> {
        let player = state.players.get(player_id)?;
        let can_play_cards = BattleRules::can_play_cards(state, player_id);
        let opponent_id = BattleRules::opponent(player_id, state);
        Some(BattleHUDSnapshot::new(
            state.phase,
            state.turn,
            player.energy,
            player.max_energy,
            player.health,
            player.max_health,
            player.block,
            opponent_id
                .as_ref()
                .and_then(|id| state.players.get(id))
                .map_or(0, |opponent| opponent.health),
            opponent_id
                .as_ref()
                .and_then(|id| state.players.get(id))
                .map_or(0, |opponent| opponent.max_health),
            opponent_id
                .as_ref()
                .and_then(|id| state.players.get(id))
                .map_or(0, |opponent| opponent.block),
            i64::try_from(player.deck.len()).expect("deck length does not fit in Int"),
            i64::try_from(player.discard.len()).expect("discard length does not fit in Int"),
            player
                .hand
                .iter()
                .map(|card| {
                    BattleHandCardViewModel::new(
                        card.id.clone(),
                        card.title.clone(),
                        card.cost,
                        can_play_cards && BattleRules::can_play(card, player_id, state),
                        card.total_damage(),
                        card.total_healing(),
                        card.total_block(),
                    )
                })
                .collect(),
            player
                .skills
                .iter()
                .map(|skill| {
                    BattleSkillViewModel::new(
                        skill.id.clone(),
                        skill.title.clone(),
                        skill.cooldown_turns,
                        skill.target,
                        can_play_cards && skill.cooldown_turns == 0,
                    )
                })
                .collect(),
        ))
    }
}
