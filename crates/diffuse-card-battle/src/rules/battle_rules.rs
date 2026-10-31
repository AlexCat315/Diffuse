//! `BattleRules` — command availability shared by the HUD and the reducer.

use crate::core::battle_state::{BattlePhase, BattleState};
use crate::rules::battle_content::BattleCard;
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleRules`.
pub struct BattleRules;

impl BattleRules {
    /// `opponent(of:in:)`. Falls back to the first other player in the map, and
    /// answers `None` when the state holds no other participant.
    pub fn opponent(of: &BattlePlayerID, in_state: &BattleState) -> Option<BattlePlayerID> {
        if *of == BattlePlayerID::player()
            && in_state.players.contains_key(&BattlePlayerID::enemy())
        {
            return Some(BattlePlayerID::enemy());
        }
        if *of == BattlePlayerID::enemy()
            && in_state.players.contains_key(&BattlePlayerID::player())
        {
            return Some(BattlePlayerID::player());
        }
        in_state
            .players
            .keys()
            .find(|candidate| *candidate != of)
            .cloned()
    }

    /// `canPlayCards(in:playerID:)`.
    pub fn can_play_cards(in_state: &BattleState, player_id: &BattlePlayerID) -> bool {
        in_state.phase == BattlePhase::Main && in_state.active_player_id == *player_id
    }

    /// `canPlay(_:for:in:)`.
    pub fn can_play(card: &BattleCard, player_id: &BattlePlayerID, in_state: &BattleState) -> bool {
        if !BattleRules::can_play_cards(in_state, player_id) {
            return false;
        }
        let Some(player) = in_state.players.get(player_id) else {
            return false;
        };
        player.energy >= card.cost
    }

    /// `canEndTurn(_:playerID:)`.
    pub fn can_end_turn(in_state: &BattleState, player_id: &BattlePlayerID) -> bool {
        in_state.phase == BattlePhase::Main && in_state.active_player_id == *player_id
    }

    /// `canResolveEnemyAction(_:)`.
    pub fn can_resolve_enemy_action(in_state: &BattleState) -> bool {
        in_state.phase == BattlePhase::EnemyTurn
            && in_state.active_player_id == BattlePlayerID::enemy()
    }
}
