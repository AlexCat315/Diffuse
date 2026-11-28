//! Default workspace regions from EditorWorkspaceDefaults.swift.

use std::collections::BTreeMap;

use cove_ui_addons::workspace::{
    WorkspaceDocument, WorkspacePanelID, WorkspacePanelRegistry, WorkspaceSlot, WorkspaceSlotID,
    WorkspaceSplitFractions, WorkspaceTabGroup, WorkspaceTabGroupID,
};
use diffuse_editor_core::state::workspace::content::EditorContent;

use super::follower::EditorContentFollower;

pub struct EditorWorkspaceDefaults;

impl EditorWorkspaceDefaults {
    pub fn make_document(registry: &WorkspacePanelRegistry, content: EditorContent) -> WorkspaceDocument {
        let panels: BTreeMap<_, _> = registry.descriptors()
            .into_iter().map(|descriptor| (descriptor.panel.id.clone(), descriptor.panel.clone())).collect();
        let mut slots = WorkspaceSlot::standard_editor_slots();
        let mut groups = BTreeMap::new();
        let preferred = EditorContentFollower::panel(content);
        let center = if panels.contains_key(&preferred) { preferred } else { "viewport".into() };
        let definitions = [
            (WorkspaceSlotID::leading(), vec!["sidebar".into()]),
            (WorkspaceSlotID::center(), vec![center]),
            (WorkspaceSlotID::trailing(), vec!["details".into()]),
            (WorkspaceSlotID::bottom(), vec!["console".into(), "terminal".into(), "developer-tools".into()]),
        ];
        for (slot, ids) in definitions {
            let mut ids: Vec<WorkspacePanelID> = ids.into_iter().filter(|id| panels.contains_key(id)).collect();
            if slot == WorkspaceSlotID::bottom() && content == EditorContent::Scene {
                ids.extend(EditorContentFollower::SCENE_TOOLS.into_iter().map(WorkspacePanelID::from)
                    .filter(|id| panels.contains_key(id)));
            }
            let id = WorkspaceTabGroupID::new(slot.as_str());
            groups.insert(id.clone(), WorkspaceTabGroup::new(id, ids));
        }
        for descriptor in registry.descriptors() {
            let panel = &descriptor.panel.id;
            if EditorContentFollower::is_placed_by_content(panel)
                || groups.values().any(|group| group.panels.contains(panel))
            {
                continue;
            }
            if let Some(group) = groups.get_mut(&WorkspaceTabGroupID::new(descriptor.default_slot.as_str())) {
                group.panels.push(panel.clone());
                if group.active_panel_id.is_none() {
                    group.active_panel_id = Some(panel.clone());
                }
            }
        }
        for group in groups.values().filter(|group| !group.panels.is_empty()) {
            if let Some(slot) = slots.get_mut(&WorkspaceSlotID::new(group.id.as_str())) {
                slot.append_group(group.id.clone());
            }
        }
        let mut document = WorkspaceDocument::new(panels, groups, slots);
        document.split_fractions = WorkspaceSplitFractions::new(Some(0.185), Some(0.678), Some(0.74), None);
        document
    }
}
