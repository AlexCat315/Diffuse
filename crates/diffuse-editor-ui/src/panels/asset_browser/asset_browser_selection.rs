//! Translation of Editor/Sources/EditorUI/Panels/AssetBrowser/AssetBrowserSelection.swift.
//!
//! Selection is clipboard-shaped: a click replaces it, Shift extends from the
//! anchor, and Ctrl/Cmd toggles one asset without moving the anchor.

use diffuse_kernel::input_event::KeyModifiers;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AssetBrowserSelectionModel {
    selected_ids: std::collections::BTreeSet<String>,
    anchor_id: Option<String>,
}

impl AssetBrowserSelectionModel {
    pub fn new() -> Self {
        AssetBrowserSelectionModel::default()
    }

    pub fn selected_ids(&self) -> &std::collections::BTreeSet<String> {
        &self.selected_ids
    }

    pub fn anchor_id(&self) -> Option<&str> {
        self.anchor_id.as_deref()
    }

    pub fn select(
        &mut self,
        asset_id: &str,
        ordered_visible_ids: &[String],
        modifiers: KeyModifiers,
    ) {
        let Some(clicked_index) = ordered_visible_ids.iter().position(|id| id == asset_id) else {
            return;
        };
        let visible: std::collections::BTreeSet<String> =
            ordered_visible_ids.iter().cloned().collect();
        self.selected_ids = self.selected_ids.intersection(&visible).cloned().collect();

        if modifiers.has_shift()
            && let Some(anchor_id) = &self.anchor_id
            && let Some(anchor_index) = ordered_visible_ids.iter().position(|id| id == anchor_id)
        {
            let lower = anchor_index.min(clicked_index);
            let upper = anchor_index.max(clicked_index);
            let range: std::collections::BTreeSet<String> =
                ordered_visible_ids[lower..=upper].iter().cloned().collect();
            if modifiers.has_ctrl() || modifiers.has_gui() {
                self.selected_ids.extend(range);
            } else {
                self.selected_ids = range;
            }
            return;
        }

        if modifiers.has_ctrl() || modifiers.has_gui() {
            if !self.selected_ids.insert(asset_id.to_string()) {
                self.selected_ids.remove(asset_id);
            }
        } else {
            self.selected_ids = std::collections::BTreeSet::from([asset_id.to_string()]);
        }
        self.anchor_id = Some(asset_id.to_string());
    }

    pub fn select_all(&mut self, ordered_visible_ids: &[String]) {
        self.selected_ids = ordered_visible_ids.iter().cloned().collect();
        self.anchor_id = ordered_visible_ids.first().cloned();
    }

    pub fn clear(&mut self) {
        self.selected_ids.clear();
        self.anchor_id = None;
    }

    pub fn adjacent_asset_id(
        asset_id: Option<&str>,
        ordered_visible_ids: &[String],
        direction: i32,
    ) -> Option<String> {
        if ordered_visible_ids.is_empty() || direction == 0 {
            return None;
        }
        let current_index = asset_id
            .and_then(|id| ordered_visible_ids.iter().position(|entry| entry == id))
            .map(|index| index as i64)
            .unwrap_or(if direction > 0 {
                -1
            } else {
                ordered_visible_ids.len() as i64
            });
        let next_index = current_index + if direction > 0 { 1 } else { -1 };
        if next_index < 0 || next_index >= ordered_visible_ids.len() as i64 {
            return None;
        }
        ordered_visible_ids.get(next_index as usize).cloned()
    }
}
