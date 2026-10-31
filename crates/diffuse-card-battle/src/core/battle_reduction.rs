//! `BattleCommandRejection`, `BattleEvent` and `BattleReductionResult`.

use serde::{Deserialize, Serialize};

use crate::core::battle_state::BattleState;
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleCommandRejection`.
///
/// Associated-value cases encode as `{"caseName": {"label": value}}` and the
/// single unlabelled payloads as `{"caseName": {"_0": value}}`
/// (MIGRATION.md §5.4).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BattleCommandRejection {
    #[serde(rename = "invalidPhase")]
    InvalidPhase {
        expected: crate::core::battle_state::BattlePhase,
        actual: crate::core::battle_state::BattlePhase,
    },
    #[serde(rename = "inactivePlayer")]
    InactivePlayer {
        expected: BattlePlayerID,
        actual: BattlePlayerID,
    },
    #[serde(rename = "missingPlayer")]
    MissingPlayer {
        #[serde(rename = "_0")]
        player_id: BattlePlayerID,
    },
    #[serde(rename = "missingCard")]
    MissingCard {
        #[serde(rename = "cardID")]
        card_id: String,
    },
    #[serde(rename = "insufficientEnergy")]
    InsufficientEnergy {
        #[serde(rename = "cardID")]
        card_id: String,
        available: i64,
        required: i64,
    },
}

/// `BattleEvent`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BattleEvent {
    #[serde(rename = "turnStarted")]
    TurnStarted {
        turn: i64,
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "cardsDrawn")]
        cards_drawn: i64,
    },
    #[serde(rename = "cardPlayed")]
    CardPlayed {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        #[serde(rename = "cardID")]
        card_id: String,
        #[serde(rename = "targetID")]
        target_id: BattlePlayerID,
        damage: i64,
    },
    #[serde(rename = "healthRestored")]
    HealthRestored {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        amount: i64,
    },
    #[serde(rename = "blockGained")]
    BlockGained {
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
        amount: i64,
    },
    #[serde(rename = "turnEnded")]
    TurnEnded {
        turn: i64,
        #[serde(rename = "playerID")]
        player_id: BattlePlayerID,
    },
    #[serde(rename = "enemyActionResolved")]
    EnemyActionResolved { damage: i64 },
    #[serde(rename = "playerDefeated")]
    PlayerDefeated {
        #[serde(rename = "_0")]
        player_id: BattlePlayerID,
    },
    #[serde(rename = "commandRejected")]
    CommandRejected {
        #[serde(rename = "_0")]
        rejection: BattleCommandRejection,
    },
}

/// `BattleReductionResult`.
///
/// Swift's `encodeIfPresent(rejection)` on an optional, an absent value is
/// omitted from the output rather than written as `null`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BattleReductionResult {
    pub state: BattleState,
    pub events: Vec<BattleEvent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection: Option<BattleCommandRejection>,
}

impl BattleReductionResult {
    /// The Swift initialiser with its defaulted `events` and `rejection`.
    pub fn new(
        state: BattleState,
        events: Vec<BattleEvent>,
        rejection: Option<BattleCommandRejection>,
    ) -> Self {
        BattleReductionResult {
            state,
            events,
            rejection,
        }
    }

    /// The Swift initialiser with no events and no rejection.
    pub fn with_state(state: BattleState) -> Self {
        BattleReductionResult::new(state, Vec::new(), None)
    }
}
