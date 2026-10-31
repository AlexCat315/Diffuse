//! Trigger overlap events.

use crate::entity_id::EntityID;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TriggerEventKind {
    Enter,
    Exit,
    Active,
}

impl TriggerEventKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            TriggerEventKind::Enter => "enter",
            TriggerEventKind::Exit => "exit",
            TriggerEventKind::Active => "active",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "enter" => Some(TriggerEventKind::Enter),
            "exit" => Some(TriggerEventKind::Exit),
            "active" => Some(TriggerEventKind::Active),
            _ => None,
        }
    }

    pub const ALL: [TriggerEventKind; 3] = [
        TriggerEventKind::Enter,
        TriggerEventKind::Exit,
        TriggerEventKind::Active,
    ];
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TriggerEvent {
    pub trigger_entity: EntityID,
    pub other_entity: EntityID,
    pub kind: TriggerEventKind,
}

impl TriggerEvent {
    pub fn new(trigger_entity: EntityID, other_entity: EntityID, kind: TriggerEventKind) -> Self {
        TriggerEvent {
            trigger_entity,
            other_entity,
            kind,
        }
    }
}

/// Per-frame trigger overlap state. Written by the schedule before scripts run.
/// Scripts read this to react to enter/exit pairs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TriggerFrameResource {
    /// Pairs that began overlapping this frame.
    pub enters: Vec<TriggerEvent>,
    /// Pairs that stopped overlapping this frame.
    pub exits: Vec<TriggerEvent>,
    /// All pairs currently overlapping this frame (enter + ongoing).
    pub active: Vec<TriggerEvent>,
}

impl TriggerFrameResource {
    pub fn new(
        enters: Vec<TriggerEvent>,
        exits: Vec<TriggerEvent>,
        active: Vec<TriggerEvent>,
    ) -> Self {
        TriggerFrameResource {
            enters,
            exits,
            active,
        }
    }

    /// Swift `isEmpty` — note it ignores `active`, so a frame with only ongoing
    /// overlaps reports empty.
    pub fn is_empty(&self) -> bool {
        self.enters.is_empty() && self.exits.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: TriggerEventKind) -> TriggerEvent {
        TriggerEvent::new(EntityID::new(1, 0), EntityID::new(2, 0), kind)
    }

    #[test]
    fn is_empty_ignores_active_pairs() {
        let frame = TriggerFrameResource::new(
            Vec::new(),
            Vec::new(),
            vec![event(TriggerEventKind::Active)],
        );
        assert!(frame.is_empty());
    }

    #[test]
    fn is_empty_is_false_when_enters_or_exits_present() {
        let enters =
            TriggerFrameResource::new(vec![event(TriggerEventKind::Enter)], Vec::new(), Vec::new());
        assert!(!enters.is_empty());
        let exits =
            TriggerFrameResource::new(Vec::new(), vec![event(TriggerEventKind::Exit)], Vec::new());
        assert!(!exits.is_empty());
    }

    #[test]
    fn event_kind_round_trips() {
        for kind in TriggerEventKind::ALL {
            assert_eq!(
                TriggerEventKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(TriggerEventKind::from_raw_value("Enter"), None);
    }

    #[test]
    fn default_frame_is_empty() {
        let frame = TriggerFrameResource::default();
        assert!(frame.is_empty());
        assert!(frame.active.is_empty());
    }
}
