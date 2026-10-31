//! `BattleSampleFactory` — the sample Three Kingdoms duel.

use std::collections::BTreeMap;

use crate::core::battle_state::{BattlePlayerState, BattleState};
use crate::rules::battle_content::{BattleCard, BattleSkill, BattleSkillTarget};
use crate::rules::battle_effect::BattleCardEffect;
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattleSampleFactory`.
pub struct BattleSampleFactory;

impl BattleSampleFactory {
    /// `makeThreeKingdomsDuel()`.
    pub fn make_three_kingdoms_duel() -> BattleState {
        let player_deck = vec![
            BattleCard::new(
                "green-dragon",
                "Green Dragon",
                5,
                Some("cleave".to_string()),
                18,
                None,
            ),
            BattleCard::new(
                "seven-strike",
                "Seven Strike",
                3,
                Some("slash".to_string()),
                9,
                None,
            ),
            BattleCard::new(
                "fire-ambush",
                "Fire Ambush",
                4,
                Some("burn".to_string()),
                14,
                None,
            ),
            BattleCard::new(
                "borrow-east",
                "Borrow East",
                2,
                Some("draw".to_string()),
                0,
                Some(vec![BattleCardEffect::block(6)]),
            ),
        ];
        let player = BattlePlayerState::new(
            BattlePlayerID::player(),
            32_000,
            Some(32_000),
            0,
            10,
            0,
            player_deck,
            Vec::new(),
            Vec::new(),
            vec![
                BattleSkill::new("slash", "Slash", 0, BattleSkillTarget::Opponent),
                BattleSkill::new("rally", "Rally", 1, BattleSkillTarget::SelfSide),
                BattleSkill::new("duel", "Duel", 2, BattleSkillTarget::Opponent),
            ],
        );
        let enemy = BattlePlayerState::new(
            BattlePlayerID::enemy(),
            32_000,
            Some(32_000),
            0,
            8,
            0,
            vec![
                BattleCard::new("halberd", "Halberd", 3, None, 10, None),
                BattleCard::new("war-cry", "War Cry", 2, None, 0, None),
            ],
            Vec::new(),
            Vec::new(),
            vec![BattleSkill::new(
                "counter",
                "Counter",
                0,
                BattleSkillTarget::Opponent,
            )],
        );
        let mut players = BTreeMap::new();
        players.insert(BattlePlayerID::player(), player);
        players.insert(BattlePlayerID::enemy(), enemy);
        BattleState::with_players(players)
    }
}
