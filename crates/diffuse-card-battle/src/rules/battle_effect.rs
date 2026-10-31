//! `BattleCardEffect` — the typed effect attached to a card.

use serde::{Deserialize, Serialize};

/// `BattleCardEffect`.
///
/// Swift's associated-value cases encode as `{"caseName": {"_0": value}}`
/// (MIGRATION.md §5.4), which is a struct variant with a field renamed to `_0`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BattleCardEffect {
    #[serde(rename = "damage")]
    Damage {
        #[serde(rename = "_0")]
        amount: i64,
    },
    #[serde(rename = "heal")]
    Heal {
        #[serde(rename = "_0")]
        amount: i64,
    },
    #[serde(rename = "block")]
    Block {
        #[serde(rename = "_0")]
        amount: i64,
    },
}

impl BattleCardEffect {
    /// `.damage(amount)`.
    pub fn damage(amount: i64) -> Self {
        BattleCardEffect::Damage { amount }
    }

    /// `.heal(amount)`.
    pub fn heal(amount: i64) -> Self {
        BattleCardEffect::Heal { amount }
    }

    /// `.block(amount)`.
    pub fn block(amount: i64) -> Self {
        BattleCardEffect::Block { amount }
    }
}
