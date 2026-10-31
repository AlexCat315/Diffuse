//! `BattlePlayerID` — the raw-value identifier for a battle participant.

use serde::{Deserialize, Serialize};

/// `BattlePlayerID`. Swift's `RawRepresentable` wrapper encodes as its raw
/// string (MIGRATION.md §5.4), so the type is transparent for serde.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct BattlePlayerID {
    pub raw_value: String,
}

impl BattlePlayerID {
    pub fn new(raw_value: impl Into<String>) -> Self {
        BattlePlayerID {
            raw_value: raw_value.into(),
        }
    }

    /// `static let player`.
    pub fn player() -> Self {
        BattlePlayerID::new("player")
    }

    /// `static let enemy`.
    pub fn enemy() -> Self {
        BattlePlayerID::new("enemy")
    }
}

impl From<&str> for BattlePlayerID {
    fn from(raw_value: &str) -> Self {
        BattlePlayerID::new(raw_value)
    }
}
