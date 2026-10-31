//! `BattleCommand` — the reducer's input vocabulary.

use serde::{Deserialize, Serialize};

use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleCommand`.
///
/// Swift's synthesized `Codable` encodes an associated-value case as
/// `{"caseName": {"label": value}}`; a case without associated values encodes as
/// `{"caseName": {}}` (MIGRATION.md §5.4).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BattleCommand {
    #[serde(rename = "startTurn")]
    StartTurn {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "drawCount")]
        draw_count: i64,
    },
    #[serde(rename = "startPlayerTurn")]
    StartPlayerTurn {
        #[serde(rename = "drawCount")]
        draw_count: i64,
    },
    #[serde(rename = "playCard")]
    PlayCard {
        #[serde(rename = "cardID")]
        card_id: String,
        target: BattlePlayerID,
    },
    #[serde(rename = "endTurn")]
    EndTurn {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
    },
    #[serde(rename = "endPlayerTurn")]
    EndPlayerTurn {},
    #[serde(rename = "resolveEnemyAction")]
    ResolveEnemyAction { damage: i64 },
}
