//! `BattleCard` and `BattleSkill` — the authored battle content.

use serde::de::{self, MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::rules::battle_effect::BattleCardEffect;

/// `BattleCard`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct BattleCard {
    pub id: String,
    pub title: String,
    pub cost: i64,
    pub skill_id: Option<String>,
    pub damage: i64,
    pub effects: Vec<BattleCardEffect>,
}

impl BattleCard {
    /// The Swift initialiser with its defaulted `skillID`, `damage` and `effects`
    /// arguments. A missing `effects` list falls back to a single `.damage`
    /// effect while `damage > 0`, otherwise to no effects.
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        cost: i64,
        skill_id: Option<String>,
        damage: i64,
        effects: Option<Vec<BattleCardEffect>>,
    ) -> Self {
        BattleCard {
            id: id.into(),
            title: title.into(),
            cost,
            skill_id,
            damage,
            effects: effects.unwrap_or_else(|| {
                if damage > 0 {
                    vec![BattleCardEffect::damage(damage)]
                } else {
                    Vec::new()
                }
            }),
        }
    }

    /// The Swift initialiser with every default applied.
    pub fn with_defaults(id: impl Into<String>, title: impl Into<String>, cost: i64) -> Self {
        BattleCard::new(id, title, cost, None, 0, None)
    }

    /// `totalDamage`.
    pub fn total_damage(&self) -> i64 {
        self.effects.iter().fold(0, |total, effect| match effect {
            BattleCardEffect::Damage { amount } => total + amount,
            BattleCardEffect::Heal { .. } | BattleCardEffect::Block { .. } => total,
        })
    }

    /// `totalHealing`.
    pub fn total_healing(&self) -> i64 {
        self.effects.iter().fold(0, |total, effect| match effect {
            BattleCardEffect::Damage { .. } => total,
            BattleCardEffect::Heal { amount } => total + amount,
            BattleCardEffect::Block { .. } => total,
        })
    }

    /// `totalBlock`.
    pub fn total_block(&self) -> i64 {
        self.effects.iter().fold(0, |total, effect| match effect {
            BattleCardEffect::Damage { .. } | BattleCardEffect::Heal { .. } => total,
            BattleCardEffect::Block { amount } => total + amount,
        })
    }
}

/// `CodingKeys` — the Swift key list, in declaration order.
const CARD_FIELDS: [&str; 6] = ["id", "title", "cost", "skillID", "damage", "effects"];

impl Serialize for BattleCard {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(None)?;
        map.serialize_entry(CARD_FIELDS[0], &self.id)?;
        map.serialize_entry(CARD_FIELDS[1], &self.title)?;
        map.serialize_entry(CARD_FIELDS[2], &self.cost)?;
        // Swift's `encodeIfPresent(skillID, forKey: .skillID)`.
        if let Some(skill_id) = &self.skill_id {
            map.serialize_entry(CARD_FIELDS[3], skill_id)?;
        }
        map.serialize_entry(CARD_FIELDS[4], &self.damage)?;
        map.serialize_entry(CARD_FIELDS[5], &self.effects)?;
        map.end()
    }
}

struct BattleCardVisitor;

impl<'de> Visitor<'de> for BattleCardVisitor {
    type Value = BattleCard;

    fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str("struct BattleCard")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<BattleCard, A::Error> {
        let mut id: Option<String> = None;
        let mut title: Option<String> = None;
        let mut cost: Option<i64> = None;
        let mut skill_id: Option<String> = None;
        let mut damage: Option<i64> = None;
        let mut effects: Option<Vec<BattleCardEffect>> = None;
        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "id" => id = Some(map.next_value()?),
                "title" => title = Some(map.next_value()?),
                "cost" => cost = Some(map.next_value()?),
                // `decodeIfPresent` turns an explicit `null` into `None`.
                "skillID" => skill_id = map.next_value()?,
                "damage" => damage = Some(map.next_value()?),
                "effects" => effects = map.next_value()?,
                // Swift's synthesized decoder skips keys it does not know.
                _ => {
                    map.next_value::<de::IgnoredAny>()?;
                }
            }
        }
        Ok(BattleCard::new(
            id.ok_or_else(|| de::Error::missing_field("id"))?,
            title.ok_or_else(|| de::Error::missing_field("title"))?,
            cost.ok_or_else(|| de::Error::missing_field("cost"))?,
            skill_id,
            damage.unwrap_or(0),
            effects,
        ))
    }
}

impl<'de> Deserialize<'de> for BattleCard {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_struct("BattleCard", &CARD_FIELDS, BattleCardVisitor)
    }
}

/// `BattleSkill.Target`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BattleSkillTarget {
    #[serde(rename = "selfSide")]
    SelfSide,
    #[serde(rename = "opponent")]
    Opponent,
    #[serde(rename = "allEnemies")]
    AllEnemies,
}

/// `BattleSkill`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct BattleSkill {
    pub id: String,
    pub title: String,
    pub cooldown_turns: i64,
    pub target: BattleSkillTarget,
}

impl BattleSkill {
    /// The Swift initialiser with its defaulted `cooldownTurns`.
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        cooldown_turns: i64,
        target: BattleSkillTarget,
    ) -> Self {
        BattleSkill {
            id: id.into(),
            title: title.into(),
            cooldown_turns,
            target,
        }
    }
}

/// `CodingKeys` — the Swift key list, in declaration order.
const SKILL_FIELDS: [&str; 4] = ["id", "title", "cooldownTurns", "target"];

impl Serialize for BattleSkill {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(None)?;
        map.serialize_entry(SKILL_FIELDS[0], &self.id)?;
        map.serialize_entry(SKILL_FIELDS[1], &self.title)?;
        map.serialize_entry(SKILL_FIELDS[2], &self.cooldown_turns)?;
        map.serialize_entry(SKILL_FIELDS[3], &self.target)?;
        map.end()
    }
}

struct BattleSkillVisitor;

impl<'de> Visitor<'de> for BattleSkillVisitor {
    type Value = BattleSkill;

    fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter.write_str("struct BattleSkill")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<BattleSkill, A::Error> {
        let mut id: Option<String> = None;
        let mut title: Option<String> = None;
        let mut cooldown_turns: Option<i64> = None;
        let mut target: Option<BattleSkillTarget> = None;
        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                "id" => id = Some(map.next_value()?),
                "title" => title = Some(map.next_value()?),
                "cooldownTurns" => cooldown_turns = Some(map.next_value()?),
                "target" => target = Some(map.next_value()?),
                // Swift's synthesized decoder skips keys it does not know.
                _ => {
                    map.next_value::<de::IgnoredAny>()?;
                }
            }
        }
        Ok(BattleSkill::new(
            id.ok_or_else(|| de::Error::missing_field("id"))?,
            title.ok_or_else(|| de::Error::missing_field("title"))?,
            cooldown_turns.ok_or_else(|| de::Error::missing_field("cooldownTurns"))?,
            target.ok_or_else(|| de::Error::missing_field("target"))?,
        ))
    }
}

impl<'de> Deserialize<'de> for BattleSkill {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_struct("BattleSkill", &SKILL_FIELDS, BattleSkillVisitor)
    }
}
