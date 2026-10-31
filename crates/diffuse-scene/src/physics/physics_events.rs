//! Contact, trigger and joint-break events.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::EntityID;
use crate::physics::queries::trigger_detection::TriggerEvent;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsContactEventKind {
    Began,
    Stayed,
    Ended,
}

impl PhysicsContactEventKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            PhysicsContactEventKind::Began => "began",
            PhysicsContactEventKind::Stayed => "stayed",
            PhysicsContactEventKind::Ended => "ended",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "began" => Some(PhysicsContactEventKind::Began),
            "stayed" => Some(PhysicsContactEventKind::Stayed),
            "ended" => Some(PhysicsContactEventKind::Ended),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsContactEvent {
    pub entity_a: EntityID,
    pub entity_b: EntityID,
    pub sub_shape_id_a: u32,
    pub sub_shape_id_b: u32,
    pub kind: PhysicsContactEventKind,
    pub position: Float3,
    pub normal: Float3,
    pub penetration_depth: f32,
    pub relative_velocity: Float3,
    pub impulse: f32,
}

impl PhysicsContactEvent {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity_a: EntityID,
        entity_b: EntityID,
        sub_shape_id_a: u32,
        sub_shape_id_b: u32,
        kind: PhysicsContactEventKind,
        position: Float3,
        normal: Float3,
        penetration_depth: f32,
        relative_velocity: Float3,
        impulse: f32,
    ) -> Self {
        PhysicsContactEvent {
            entity_a,
            entity_b,
            sub_shape_id_a,
            sub_shape_id_b,
            kind,
            position,
            normal,
            penetration_depth,
            relative_velocity,
            impulse,
        }
    }

    /// Swift's convenience initializer for contact pairs that carry no geometry.
    pub fn from_kind(
        entity_a: EntityID,
        entity_b: EntityID,
        kind: PhysicsContactEventKind,
    ) -> Self {
        PhysicsContactEvent {
            entity_a,
            entity_b,
            sub_shape_id_a: 0,
            sub_shape_id_b: 0,
            kind,
            position: Float3::ZERO,
            normal: Float3::ZERO,
            penetration_depth: 0.0,
            relative_velocity: Float3::ZERO,
            impulse: 0.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsJointBreakEvent {
    pub joint_entity: EntityID,
    pub entity_a: EntityID,
    pub entity_b: EntityID,
    pub force: f32,
    pub torque: f32,
}

impl PhysicsJointBreakEvent {
    pub fn new(
        joint_entity: EntityID,
        entity_a: EntityID,
        entity_b: EntityID,
        force: f32,
        torque: f32,
    ) -> Self {
        PhysicsJointBreakEvent {
            joint_entity,
            entity_a,
            entity_b,
            force,
            torque,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsEventFrameResource {
    pub contacts: Vec<PhysicsContactEvent>,
    pub triggers: Vec<TriggerEvent>,
    pub joint_breaks: Vec<PhysicsJointBreakEvent>,
    pub did_overflow: bool,
}

impl PhysicsEventFrameResource {
    pub fn new(
        contacts: Vec<PhysicsContactEvent>,
        triggers: Vec<TriggerEvent>,
        joint_breaks: Vec<PhysicsJointBreakEvent>,
        did_overflow: bool,
    ) -> Self {
        PhysicsEventFrameResource {
            contacts,
            triggers,
            joint_breaks,
            did_overflow,
        }
    }

    pub fn empty() -> Self {
        PhysicsEventFrameResource::default()
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsContactFrameResource {
    pub began: Vec<PhysicsContactEvent>,
    pub stayed: Vec<PhysicsContactEvent>,
    pub ended: Vec<PhysicsContactEvent>,
}

impl PhysicsContactFrameResource {
    /// Partitions events in first-seen order per kind.
    pub fn from_events(events: &[PhysicsContactEvent]) -> Self {
        PhysicsContactFrameResource {
            began: events
                .iter()
                .filter(|event| event.kind == PhysicsContactEventKind::Began)
                .copied()
                .collect(),
            stayed: events
                .iter()
                .filter(|event| event.kind == PhysicsContactEventKind::Stayed)
                .copied()
                .collect(),
            ended: events
                .iter()
                .filter(|event| event.kind == PhysicsContactEventKind::Ended)
                .copied()
                .collect(),
        }
    }

    pub fn with_partitions(
        began: Vec<PhysicsContactEvent>,
        stayed: Vec<PhysicsContactEvent>,
        ended: Vec<PhysicsContactEvent>,
    ) -> Self {
        PhysicsContactFrameResource {
            began,
            stayed,
            ended,
        }
    }

    /// Concatenation order: began, then stayed, then ended.
    pub fn events(&self) -> Vec<PhysicsContactEvent> {
        let mut all = Vec::with_capacity(self.began.len() + self.stayed.len() + self.ended.len());
        all.extend_from_slice(&self.began);
        all.extend_from_slice(&self.stayed);
        all.extend_from_slice(&self.ended);
        all
    }

    pub fn empty() -> Self {
        PhysicsContactFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contact(kind: PhysicsContactEventKind, a: u32) -> PhysicsContactEvent {
        PhysicsContactEvent::from_kind(EntityID::new(a, 0), EntityID::new(9, 0), kind)
    }

    #[test]
    fn contact_convenience_initializer_zeroes_geometry() {
        let event = contact(PhysicsContactEventKind::Began, 1);
        assert_eq!(event.sub_shape_id_a, 0);
        assert_eq!(event.position, Float3::ZERO);
        assert_eq!(event.impulse, 0.0);
    }

    #[test]
    fn frame_partitions_by_kind() {
        let events = vec![
            contact(PhysicsContactEventKind::Began, 1),
            contact(PhysicsContactEventKind::Stayed, 2),
            contact(PhysicsContactEventKind::Ended, 3),
            contact(PhysicsContactEventKind::Began, 4),
        ];
        let frame = PhysicsContactFrameResource::from_events(&events);
        assert_eq!(frame.began.len(), 2);
        assert_eq!(frame.stayed.len(), 1);
        assert_eq!(frame.ended.len(), 1);
    }

    #[test]
    fn events_concatenate_in_began_stayed_ended_order() {
        let frame = PhysicsContactFrameResource::with_partitions(
            vec![contact(PhysicsContactEventKind::Began, 1)],
            vec![contact(PhysicsContactEventKind::Stayed, 2)],
            vec![contact(PhysicsContactEventKind::Ended, 3)],
        );
        let all = frame.events();
        assert_eq!(all[0].kind, PhysicsContactEventKind::Began);
        assert_eq!(all[1].kind, PhysicsContactEventKind::Stayed);
        assert_eq!(all[2].kind, PhysicsContactEventKind::Ended);
    }

    #[test]
    fn contact_kind_round_trips() {
        for kind in [
            PhysicsContactEventKind::Began,
            PhysicsContactEventKind::Stayed,
            PhysicsContactEventKind::Ended,
        ] {
            assert_eq!(
                PhysicsContactEventKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(PhysicsContactEventKind::from_raw_value("begin"), None);
    }

    #[test]
    fn default_event_frame_does_not_overflow() {
        assert!(!PhysicsEventFrameResource::empty().did_overflow);
    }
}
