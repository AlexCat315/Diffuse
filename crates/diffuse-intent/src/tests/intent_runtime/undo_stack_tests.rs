//! Undo-stack half of `Engine/Tests/IntentRuntimeTests/IntentRuntimeTests.swift`.

use diffuse_math::simd::simd_compat::Float3;

use super::intent_runtime_tests::{scene, scene_context};
use crate::intent_runtime_coordinator::IntentRuntimeCoordinator;
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionBaseRevisions, TransactionIR, TransactionOperation,
    TransactionProvenance,
};
use crate::transactions::undo_stack::UndoStack;

fn spawn_transaction(revision: u64, label: &str) -> TransactionIR {
    let mut transaction = TransactionIR::new(
        format!("Spawn {label}"),
        vec![TransactionOperation::Scene(
            SceneMutation::SpawnImportedMeshEntity {
                label: label.to_string(),
                kind_label: "Mesh".to_string(),
                mesh_index: 0,
                position: Float3::ZERO,
                parent_id: None,
            },
        )],
        TransactionProvenance::Authored,
    );
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(revision),
        ..TransactionBaseRevisions::default()
    };
    transaction
}

/// Push / undo / redo round-trip restores snapshots in the correct order.
#[test]
fn push_undo_redo_round_trip() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut context = scene_context(scene());

    let r0 = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .snapshot()
        .revision;
    coordinator
        .submit_plan(
            &spawn_transaction(r0, "Entity"),
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("first apply");
    let r1 = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .snapshot()
        .revision;
    coordinator
        .submit_plan(
            &spawn_transaction(r1, "Entity"),
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("second apply");
    let r2 = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .snapshot()
        .revision;

    assert_eq!(coordinator.undo_stack_depths(), (2, 0));
    assert!(coordinator.undo_stack_depths().0 > 0);
    assert_eq!(coordinator.undo_stack_depths().1, 0);

    assert!(coordinator.undo(&mut context));
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        Some(r1)
    );
    assert_eq!(coordinator.undo_stack_depths(), (1, 1));

    coordinator.undo(&mut context);
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        Some(r0)
    );
    assert_eq!(coordinator.undo_stack_depths(), (0, 2));

    coordinator.redo(&mut context);
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        Some(r1)
    );
    coordinator.redo(&mut context);
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        Some(r2)
    );
    assert_eq!(coordinator.undo_stack_depths(), (2, 0));
}

/// A push clears the redo stack.
#[test]
fn push_clears_redo_stack() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut context = scene_context(scene());

    let r0 = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .snapshot()
        .revision;
    coordinator
        .submit_plan(
            &spawn_transaction(r0, "Entity"),
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("first apply");
    coordinator.undo(&mut context);
    assert!(coordinator.undo_stack_depths().1 > 0);

    coordinator
        .submit_plan(
            &spawn_transaction(r0, "Entity"),
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("second apply");
    assert_eq!(coordinator.undo_stack_depths().1, 0);
}

/// Undo on an empty stack returns false without modifying the context.
#[test]
fn undo_on_empty_stack_returns_false() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut context = scene_context(scene());
    let revision_before = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .snapshot()
        .revision;

    assert!(!coordinator.undo(&mut context));
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        Some(revision_before)
    );
}

/// The ring buffer discards the oldest entry when capacity is exceeded.
#[test]
fn ring_buffer_evicts_oldest() {
    let mut stack = UndoStack::new(3);
    let scenes: Vec<_> = (0..4).map(|_| scene()).collect();

    stack.push(scenes[0].clone());
    stack.push(scenes[1].clone());
    stack.push(scenes[2].clone());
    stack.push(scenes[3].clone());

    assert_eq!(stack.undo_depth(), 3);
    assert!(stack.undo(scene()).is_some());
    assert!(stack.undo(scene()).is_some());
    assert!(stack.undo(scene()).is_some());
    assert_eq!(stack.undo_depth(), 0);
}
