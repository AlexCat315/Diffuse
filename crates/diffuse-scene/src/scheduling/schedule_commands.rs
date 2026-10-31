//! The deferred command buffer used by `SceneRuntime`.

use crate::entity_id::EntityID;
use crate::runtime_world::LocalTransform;

/// `RuntimeSystemPhase` — a `String`-backed `CaseIterable` enum.
///
/// The derived `Ord` follows declaration order, which is the frame's execution
/// order, so ordered collections of phases iterate in the order they run.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum RuntimeSystemPhase {
    CommandApply,
    HierarchyPropagate,
    InputAndPrePhysicsScripts,
    FixedPhysicsPrepare,
    FixedPhysicsStep,
    PhysicsWriteback,
    TriggerDetection,
    PostPhysicsScripts,
    SpatialIndexUpdate,
    RenderExtract,
}

impl RuntimeSystemPhase {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RuntimeSystemPhase::CommandApply => "commandApply",
            RuntimeSystemPhase::HierarchyPropagate => "hierarchyPropagate",
            RuntimeSystemPhase::InputAndPrePhysicsScripts => "inputAndPrePhysicsScripts",
            RuntimeSystemPhase::FixedPhysicsPrepare => "fixedPhysicsPrepare",
            RuntimeSystemPhase::FixedPhysicsStep => "fixedPhysicsStep",
            RuntimeSystemPhase::PhysicsWriteback => "physicsWriteback",
            RuntimeSystemPhase::TriggerDetection => "triggerDetection",
            RuntimeSystemPhase::PostPhysicsScripts => "postPhysicsScripts",
            RuntimeSystemPhase::SpatialIndexUpdate => "spatialIndexUpdate",
            RuntimeSystemPhase::RenderExtract => "renderExtract",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "commandApply" => Some(RuntimeSystemPhase::CommandApply),
            "hierarchyPropagate" => Some(RuntimeSystemPhase::HierarchyPropagate),
            "inputAndPrePhysicsScripts" => Some(RuntimeSystemPhase::InputAndPrePhysicsScripts),
            "fixedPhysicsPrepare" => Some(RuntimeSystemPhase::FixedPhysicsPrepare),
            "fixedPhysicsStep" => Some(RuntimeSystemPhase::FixedPhysicsStep),
            "physicsWriteback" => Some(RuntimeSystemPhase::PhysicsWriteback),
            "triggerDetection" => Some(RuntimeSystemPhase::TriggerDetection),
            "postPhysicsScripts" => Some(RuntimeSystemPhase::PostPhysicsScripts),
            "spatialIndexUpdate" => Some(RuntimeSystemPhase::SpatialIndexUpdate),
            "renderExtract" => Some(RuntimeSystemPhase::RenderExtract),
            _ => None,
        }
    }

    /// `CaseIterable` declaration order — the execution order of the frame.
    pub const ALL: [RuntimeSystemPhase; 10] = [
        RuntimeSystemPhase::CommandApply,
        RuntimeSystemPhase::HierarchyPropagate,
        RuntimeSystemPhase::InputAndPrePhysicsScripts,
        RuntimeSystemPhase::FixedPhysicsPrepare,
        RuntimeSystemPhase::FixedPhysicsStep,
        RuntimeSystemPhase::PhysicsWriteback,
        RuntimeSystemPhase::TriggerDetection,
        RuntimeSystemPhase::PostPhysicsScripts,
        RuntimeSystemPhase::SpatialIndexUpdate,
        RuntimeSystemPhase::RenderExtract,
    ];
}

#[derive(Clone, Debug, PartialEq)]
pub enum RuntimeCommand {
    CreateEntity,
    DestroyEntity(EntityID),
    SetParent {
        parent: Option<EntityID>,
        child: EntityID,
    },
    SetLocalTransform {
        entity: EntityID,
        transform: LocalTransform,
    },
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RuntimeCommandBuffer {
    commands: Vec<RuntimeCommand>,
}

impl RuntimeCommandBuffer {
    pub fn new() -> Self {
        RuntimeCommandBuffer::default()
    }

    pub fn count(&self) -> usize {
        self.commands.len()
    }

    pub fn is_empty(&self) -> bool {
        self.commands.is_empty()
    }

    pub fn enqueue(&mut self, command: RuntimeCommand) {
        self.commands.push(command);
    }

    pub fn create_entity(&mut self) {
        self.enqueue(RuntimeCommand::CreateEntity);
    }

    pub fn destroy_entity(&mut self, entity: EntityID) {
        self.enqueue(RuntimeCommand::DestroyEntity(entity));
    }

    pub fn set_parent(&mut self, parent: Option<EntityID>, child: EntityID) {
        self.enqueue(RuntimeCommand::SetParent { parent, child });
    }

    pub fn set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) {
        self.enqueue(RuntimeCommand::SetLocalTransform { entity, transform });
    }

    /// Removes and returns every buffered command, keeping the allocation.
    pub fn drain(&mut self) -> Vec<RuntimeCommand> {
        std::mem::take(&mut self.commands)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phases_round_trip_and_keep_execution_order() {
        for phase in RuntimeSystemPhase::ALL {
            assert_eq!(
                RuntimeSystemPhase::from_raw_value(phase.raw_value()),
                Some(phase)
            );
        }
        assert_eq!(RuntimeSystemPhase::ALL[0], RuntimeSystemPhase::CommandApply);
        assert_eq!(
            RuntimeSystemPhase::ALL[9],
            RuntimeSystemPhase::RenderExtract
        );
    }

    #[test]
    fn buffer_accumulates_and_drains() {
        let mut buffer = RuntimeCommandBuffer::new();
        assert!(buffer.is_empty());
        buffer.create_entity();
        buffer.destroy_entity(EntityID::new(3, 0));
        buffer.set_parent(Some(EntityID::new(1, 0)), EntityID::new(2, 0));
        buffer.set_local_transform(LocalTransform::IDENTITY, EntityID::new(4, 0));
        assert_eq!(buffer.count(), 4);

        let drained = buffer.drain();
        assert_eq!(drained.len(), 4);
        assert!(buffer.is_empty());
        assert_eq!(drained[0], RuntimeCommand::CreateEntity);
        assert_eq!(
            drained[2],
            RuntimeCommand::SetParent {
                parent: Some(EntityID::new(1, 0)),
                child: EntityID::new(2, 0),
            }
        );
    }

    #[test]
    fn drain_then_enqueue_starts_fresh() {
        let mut buffer = RuntimeCommandBuffer::new();
        buffer.create_entity();
        let _ = buffer.drain();
        buffer.create_entity();
        assert_eq!(buffer.count(), 1);
    }
}
