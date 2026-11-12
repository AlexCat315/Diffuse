//! Ported from `Editor/Tests/EditorCoreTests/EditorSelectionReducerTests.swift`.

use std::collections::BTreeSet;

use diffuse_kernel::input_event::KeyModifiers;

use crate::editing::editor_selection_reducer::EditorSelectionReducer;
use crate::state::editor_state::SelectionPrimaryModifierBehavior;

fn set(values: &[u64]) -> BTreeSet<u64> {
    values.iter().copied().collect()
}

/// Shift adds picked entities.
#[test]
fn shift_adds_picked_entities() {
    let result = EditorSelectionReducer::merge(
        &set(&[1, 2]),
        &set(&[2, 3]),
        KeyModifiers::LEFT_SHIFT,
        SelectionPrimaryModifierBehavior::Subtract,
    );
    assert_eq!(result, set(&[1, 2, 3]));
}

/// Primary modifier subtract behavior removes picked entities.
#[test]
fn primary_modifier_subtract_removes_picked_entities() {
    let result = EditorSelectionReducer::merge(
        &set(&[1, 2, 3]),
        &set(&[2, 4]),
        KeyModifiers::LEFT_GUI,
        SelectionPrimaryModifierBehavior::Subtract,
    );
    assert_eq!(result, set(&[1, 3]));
}

/// Primary modifier toggle behavior flips picked entities.
#[test]
fn primary_modifier_toggle_flips_picked_entities() {
    let result = EditorSelectionReducer::merge(
        &set(&[1, 2]),
        &set(&[2, 3]),
        KeyModifiers::LEFT_CTRL,
        SelectionPrimaryModifierBehavior::Toggle,
    );
    assert_eq!(result, set(&[1, 3]));
}
