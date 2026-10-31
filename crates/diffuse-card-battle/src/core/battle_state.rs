//! `BattleState` and `BattlePlayerState` — the reducer's state.

use std::collections::BTreeMap;

use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::ser::{SerializeMap, SerializeSeq};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::rules::battle_content::{BattleCard, BattleSkill};
use crate::support::battle_identifiers::BattlePlayerID;

/// `BattlePlayerState`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BattlePlayerState {
    pub id: BattlePlayerID,
    pub health: i64,
    pub max_health: i64,
    pub block: i64,
    pub max_energy: i64,
    pub energy: i64,
    pub deck: Vec<BattleCard>,
    pub hand: Vec<BattleCard>,
    pub discard: Vec<BattleCard>,
    pub skills: Vec<BattleSkill>,
}

impl BattlePlayerState {
    /// The Swift initialiser with every defaulted argument applied: `maxHealth`
    /// falls back to `health`, the counters to zero and the piles to empty.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: BattlePlayerID,
        health: i64,
        max_health: Option<i64>,
        block: i64,
        max_energy: i64,
        energy: i64,
        deck: Vec<BattleCard>,
        hand: Vec<BattleCard>,
        discard: Vec<BattleCard>,
        skills: Vec<BattleSkill>,
    ) -> Self {
        BattlePlayerState {
            id,
            health,
            max_health: max_health.unwrap_or(health),
            block,
            max_energy,
            energy,
            deck,
            hand,
            discard,
            skills,
        }
    }

    /// The Swift initialiser with the trailing arguments defaulted.
    pub fn with_defaults(
        id: BattlePlayerID,
        health: i64,
        max_energy: i64,
        deck: Vec<BattleCard>,
    ) -> Self {
        BattlePlayerState::new(
            id,
            health,
            None,
            0,
            max_energy,
            0,
            deck,
            Vec::new(),
            Vec::new(),
            Vec::new(),
        )
    }
}

/// `CodingKeys` — the Swift key list, in declaration order.
const PLAYER_FIELDS: [&str; 10] = [
    "id",
    "health",
    "maxHealth",
    "block",
    "maxEnergy",
    "energy",
    "deck",
    "hand",
    "discard",
    "skills",
];

impl Serialize for BattlePlayerState {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(None)?;
        map.serialize_entry(PLAYER_FIELDS[0], &self.id)?;
        map.serialize_entry(PLAYER_FIELDS[1], &self.health)?;
        map.serialize_entry(PLAYER_FIELDS[2], &self.max_health)?;
        map.serialize_entry(PLAYER_FIELDS[3], &self.block)?;
        map.serialize_entry(PLAYER_FIELDS[4], &self.max_energy)?;
        map.serialize_entry(PLAYER_FIELDS[5], &self.energy)?;
        map.serialize_entry(PLAYER_FIELDS[6], &self.deck)?;
        map.serialize_entry(PLAYER_FIELDS[7], &self.hand)?;
        map.serialize_entry(PLAYER_FIELDS[8], &self.discard)?;
        map.serialize_entry(PLAYER_FIELDS[9], &self.skills)?;
        map.end()
    }
}

struct BattlePlayerStateVisitor;

impl<'de> Visitor<'de> for BattlePlayerStateVisitor {
    type Value = BattlePlayerState;

    fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str("struct BattlePlayerState")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<BattlePlayerState, A::Error> {
        let mut id: Option<BattlePlayerID> = None;
        let mut health: Option<i64> = None;
        let mut max_health: Option<i64> = None;
        let mut block: Option<i64> = None;
        let mut max_energy: Option<i64> = None;
        let mut energy: Option<i64> = None;
        let mut deck: Option<Vec<BattleCard>> = None;
        let mut hand: Option<Vec<BattleCard>> = None;
        let mut discard: Option<Vec<BattleCard>> = None;
        let mut skills: Option<Vec<BattleSkill>> = None;
        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "id" => id = Some(map.next_value()?),
                "health" => health = Some(map.next_value()?),
                "maxHealth" => max_health = map.next_value()?,
                "block" => block = map.next_value()?,
                "maxEnergy" => max_energy = Some(map.next_value()?),
                "energy" => energy = map.next_value()?,
                "deck" => deck = Some(map.next_value()?),
                "hand" => hand = map.next_value()?,
                "discard" => discard = map.next_value()?,
                "skills" => skills = map.next_value()?,
                // Swift's synthesized decoder skips keys it does not know.
                _ => {
                    map.next_value::<de::IgnoredAny>()?;
                }
            }
        }
        Ok(BattlePlayerState::new(
            id.ok_or_else(|| de::Error::missing_field("id"))?,
            health.ok_or_else(|| de::Error::missing_field("health"))?,
            max_health,
            block.unwrap_or(0),
            max_energy.ok_or_else(|| de::Error::missing_field("maxEnergy"))?,
            energy.unwrap_or(0),
            deck.ok_or_else(|| de::Error::missing_field("deck"))?,
            hand.unwrap_or_default(),
            discard.unwrap_or_default(),
            skills.unwrap_or_default(),
        ))
    }
}

impl<'de> Deserialize<'de> for BattlePlayerState {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_struct(
            "BattlePlayerState",
            &PLAYER_FIELDS,
            BattlePlayerStateVisitor,
        )
    }
}

/// `BattlePhase`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BattlePhase {
    #[serde(rename = "setup")]
    Setup,
    #[serde(rename = "draw")]
    Draw,
    #[serde(rename = "main")]
    Main,
    #[serde(rename = "resolvingCard")]
    ResolvingCard,
    #[serde(rename = "enemyTurn")]
    EnemyTurn,
    #[serde(rename = "victory")]
    Victory,
    #[serde(rename = "defeat")]
    Defeat,
}

/// `BattleState`.
///
/// `players` is a `BTreeMap` so iteration and output order are stable
/// (MIGRATION.md §5.2). Swift encoded the dictionary as an alternating
/// key/value array, reproduced byte for byte here (§5.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BattleState {
    pub phase: BattlePhase,
    pub turn: i64,
    pub active_player_id: BattlePlayerID,
    pub players: BTreeMap<BattlePlayerID, BattlePlayerState>,
    pub log: Vec<String>,
}

impl BattleState {
    /// The Swift initialiser with its arguments in declaration order.
    pub fn new(
        phase: BattlePhase,
        turn: i64,
        active_player_id: BattlePlayerID,
        players: BTreeMap<BattlePlayerID, BattlePlayerState>,
        log: Vec<String>,
    ) -> Self {
        BattleState {
            phase,
            turn,
            active_player_id,
            players,
            log,
        }
    }

    /// The Swift initialiser with `.setup`, turn zero, the `player` actor and an
    /// empty log.
    pub fn with_players(players: BTreeMap<BattlePlayerID, BattlePlayerState>) -> Self {
        BattleState::new(
            BattlePhase::Setup,
            0,
            BattlePlayerID::player(),
            players,
            Vec::new(),
        )
    }
}

/// `CodingKeys` — the Swift key list, in declaration order.
const STATE_FIELDS: [&str; 5] = ["phase", "turn", "activePlayerID", "players", "log"];

/// The player map in Swift's alternating `[key, value, …]` array form. Used for
/// deserialisation; serialisation borrows the map through [`PlayersArrayRef`].
struct PlayersArray(BTreeMap<BattlePlayerID, BattlePlayerState>);

/// Borrowing counterpart of [`PlayersArray`].
struct PlayersArrayRef<'a>(&'a BTreeMap<BattlePlayerID, BattlePlayerState>);

impl Serialize for PlayersArrayRef<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(self.0.len() * 2))?;
        for (key, value) in self.0 {
            sequence.serialize_element(key)?;
            sequence.serialize_element(value)?;
        }
        sequence.end()
    }
}

impl<'de> Deserialize<'de> for PlayersArray {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_seq(PlayersArrayVisitor)
    }
}

struct PlayersArrayVisitor;

impl<'de> Visitor<'de> for PlayersArrayVisitor {
    type Value = PlayersArray;

    fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str("an array of alternating player identifiers and states")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<PlayersArray, A::Error> {
        let mut players = BTreeMap::new();
        while let Some(key) = sequence.next_element::<BattlePlayerID>()? {
            let value = sequence
                .next_element::<BattlePlayerState>()?
                .ok_or_else(|| de::Error::custom("missing player state for player identifier"))?;
            players.insert(key, value);
        }
        Ok(PlayersArray(players))
    }
}

impl Serialize for BattleState {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(None)?;
        map.serialize_entry(STATE_FIELDS[0], &self.phase)?;
        map.serialize_entry(STATE_FIELDS[1], &self.turn)?;
        map.serialize_entry(STATE_FIELDS[2], &self.active_player_id)?;
        map.serialize_entry(STATE_FIELDS[3], &PlayersArrayRef(&self.players))?;
        map.serialize_entry(STATE_FIELDS[4], &self.log)?;
        map.end()
    }
}

struct BattleStateVisitor;

impl<'de> Visitor<'de> for BattleStateVisitor {
    type Value = BattleState;

    fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str("struct BattleState")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<BattleState, A::Error> {
        let mut phase: Option<BattlePhase> = None;
        let mut turn: Option<i64> = None;
        let mut active_player_id: Option<BattlePlayerID> = None;
        let mut players: Option<BTreeMap<BattlePlayerID, BattlePlayerState>> = None;
        let mut log: Option<Vec<String>> = None;
        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "phase" => phase = Some(map.next_value()?),
                "turn" => turn = Some(map.next_value()?),
                "activePlayerID" => active_player_id = Some(map.next_value()?),
                "players" => players = Some(map.next_value::<PlayersArray>()?.0),
                "log" => log = Some(map.next_value()?),
                // Swift's synthesized decoder skips keys it does not know.
                _ => {
                    map.next_value::<de::IgnoredAny>()?;
                }
            }
        }
        Ok(BattleState::new(
            phase.ok_or_else(|| de::Error::missing_field("phase"))?,
            turn.ok_or_else(|| de::Error::missing_field("turn"))?,
            active_player_id.ok_or_else(|| de::Error::missing_field("activePlayerID"))?,
            players.ok_or_else(|| de::Error::missing_field("players"))?,
            log.ok_or_else(|| de::Error::missing_field("log"))?,
        ))
    }
}

impl<'de> Deserialize<'de> for BattleState {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_struct("BattleState", &STATE_FIELDS, BattleStateVisitor)
    }
}
