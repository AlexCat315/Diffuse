//! `Editor/Sources/EditorCore/Editing/EditorSelectionReducer.swift`.

use std::collections::BTreeSet;

use diffuse_kernel::input_event::KeyModifiers;

use crate::state::editor_state::SelectionPrimaryModifierBehavior;

pub struct EditorSelectionReducer;

impl EditorSelectionReducer {
    pub fn merge(
        base: &BTreeSet<u64>,
        picked: &BTreeSet<u64>,
        modifiers: KeyModifiers,
        primary_modifier_behavior: SelectionPrimaryModifierBehavior,
    ) -> BTreeSet<u64> {
        if modifiers.has_shift() {
            return base.union(picked).copied().collect();
        }
        if modifiers.has_ctrl() || modifiers.has_gui() {
            return match primary_modifier_behavior {
                SelectionPrimaryModifierBehavior::Subtract => {
                    base.difference(picked).copied().collect()
                }
                SelectionPrimaryModifierBehavior::Toggle => {
                    let mut next = base.clone();
                    for item in picked {
                        if next.contains(item) {
                            next.remove(item);
                        } else {
                            next.insert(*item);
                        }
                    }
                    next
                }
            };
        }
        picked.clone()
    }

    pub fn merge_single(
        base: &BTreeSet<u64>,
        picked: Option<u64>,
        modifiers: KeyModifiers,
        primary_modifier_behavior: SelectionPrimaryModifierBehavior,
    ) -> BTreeSet<u64> {
        let Some(picked) = picked else {
            if modifiers.has_shift() || modifiers.has_ctrl() || modifiers.has_gui() {
                return base.clone();
            }
            return BTreeSet::new();
        };
        Self::merge(
            base,
            &BTreeSet::from([picked]),
            modifiers,
            primary_modifier_behavior,
        )
    }
}
